#include "ScreamBarAsyncSRC.h"

#include "ScreamBarSPSCRingBuffer.h"

#include <CoreAudio/HostTime.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(
    ATOMIC_BOOL_LOCK_FREE == 2
        && ATOMIC_INT_LOCK_FREE == 2
        && ATOMIC_LONG_LOCK_FREE == 2
        && ATOMIC_LLONG_LOCK_FREE == 2,
    "The real-time SRC path requires always-lock-free integer atomics"
);

static const double SCREAM_BAR_MINIMUM_FILL_ERROR_TIME_CONSTANT_SECONDS = 0.25;
static const double SCREAM_BAR_MINIMUM_FILL_CORRECTION_SECONDS = 1.0;
static const double SCREAM_BAR_PLAYBACK_RATE_TIME_CONSTANT_SECONDS = 0.25;
static const double SCREAM_BAR_PLAYBACK_RATE_DEADBAND = 0.000001;
static const double SCREAM_BAR_RATE_LOCK_SETTLING_SECONDS = 3.0;
static const double SCREAM_BAR_RATE_LOCK_MAXIMUM_DELTA = 0.000005;
static const double SCREAM_BAR_RATE_LOCK_MINIMUM_FILL_DELTA_FRAMES = 4.0;
static const double SCREAM_BAR_RATE_LOCK_FILL_QUANTUM_DIVISOR = 4.0;
static const double SCREAM_BAR_FALLBACK_FILL_ERROR_TIME_CONSTANT_SECONDS = 5.0;
static const double SCREAM_BAR_FALLBACK_FILL_CORRECTION_SECONDS = 5.0;
static const double SCREAM_BAR_FALLBACK_PLAYBACK_RATE_TIME_CONSTANT_SECONDS = 1.2;
static const double SCREAM_BAR_CALLBACK_SMOOTHING_COUNT = 64.0;
static const double SCREAM_BAR_TARGET_CORRECTION_MULTIPLIER = 100.0;
static const double SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION = 0.0015;
static const double SCREAM_BAR_STABLE_SECONDS_BEFORE_TARGET_REDUCTION = 60.0;
static const uint32_t SCREAM_BAR_SOURCE_FRAME_MARGIN = 64;
static const uint32_t SCREAM_BAR_LOW_WATER_GUARD_DIVISOR = 4;
static const uint32_t SCREAM_BAR_TARGET_GROWTH_DIVISOR = 2;
static const uint32_t SCREAM_BAR_TELEMETRY_PUBLISH_INTERVAL = 64;

struct ScreamBarAsyncSRCClockController {
    double averaged_fill_error_frames;
    double estimated_input_quantum_frames;
    double previous_readable_frames;
    double previous_source_frames;
    double smoothed_playback_rate;
    double adaptation_elapsed_seconds;
    double locked_fill_error_frames;
    bool has_previous_observation;
    bool playback_rate_locked;
};

struct ScreamBarAsyncSRCContext {
    AudioUnit input_audio_unit;
    AudioUnit varispeed_audio_unit;
    ScreamBarAsyncSRCInputRenderProc input_render_proc;
    void *input_render_context;
    ScreamBarSPSCRingBuffer *ring_buffer;
    ScreamBarAsyncSRCClockController *clock_controller;
    AudioBufferList *input_buffer_list;
    Float32 *input_samples;
    Float32 *source_samples;
    uint32_t input_channel_count;
    uint32_t output_channel_count;
    uint32_t maximum_input_frames;
    uint32_t maximum_output_frames;
    uint32_t maximum_source_frames;
    uint32_t ring_capacity_frames;
    uint32_t initial_target_fill_frames;
    uint32_t maximum_target_fill_frames;
    uint32_t maximum_readable_frames;
    double input_sample_rate;
    double output_sample_rate;
    double input_callback_deadline_host_ticks_per_frame;
    double output_callback_deadline_host_ticks_per_frame;
    bool low_latency;
    bool adaptive_clock_control;
    uint64_t stable_output_frames;
    uint64_t fifo_fill_sample_count;
    uint64_t fifo_fill_frame_sum;
    uint64_t playback_rate_adjustment_count;
    uint32_t minimum_fifo_fill_frames;
    uint32_t maximum_fifo_fill_frames;
    double minimum_playback_rate;
    double maximum_playback_rate;
    double last_applied_playback_rate;
    uint32_t telemetry_callbacks_until_publish;
    bool has_applied_playback_rate;
    bool telemetry_saturated;
    _Atomic bool primed;
    _Atomic uint_fast64_t captured_frames;
    _Atomic uint_fast64_t rendered_frames;
    _Atomic uint_fast64_t priming_silence_frames;
    _Atomic uint_fast64_t dropped_input_frames;
    _Atomic uint_fast64_t underrun_count;
    _Atomic uint_fast64_t latency_ceiling_underrun_count;
    _Atomic uint_fast64_t overflow_count;
    _Atomic uint_fast64_t resynchronization_count;
    _Atomic uint_fast64_t startup_trim_count;
    _Atomic uint_fast64_t startup_trimmed_frames;
    _Atomic uint_fast64_t input_render_error_count;
    _Atomic uint_fast64_t output_render_error_count;
    _Atomic uint_fast64_t rate_parameter_error_count;
    _Atomic uint_fast64_t input_callback_deadline_miss_count;
    _Atomic uint_fast64_t output_callback_deadline_miss_count;
    _Atomic uint_fast64_t published_fifo_fill_sample_count;
    _Atomic uint_fast64_t published_fifo_fill_frame_sum;
    _Atomic uint_fast64_t published_playback_rate_adjustment_count;
    _Atomic uint_fast64_t published_telemetry_generation;
    _Atomic bool published_telemetry_saturated;
    _Atomic uint_fast64_t latency_ceiling_overflow_count;
    _Atomic uint_fast64_t input_callback_frame_limit_exceeded_count;
    _Atomic uint_fast64_t output_callback_frame_limit_exceeded_count;
    _Atomic uint_fast32_t target_fill_frames;
    _Atomic uint_fast32_t maximum_input_callback_frames;
    _Atomic uint_fast32_t maximum_output_callback_frames;
    _Atomic uint_fast32_t maximum_source_callback_frames;
    _Atomic uint_fast32_t source_frames_for_current_output_callback;
    _Atomic uint_fast32_t maximum_source_frames_per_output_callback;
    _Atomic uint_fast32_t last_source_requested_frames;
    _Atomic uint_fast32_t last_source_readable_frames;
    _Atomic uint_fast32_t underrun_source_requested_frames;
    _Atomic uint_fast32_t underrun_source_readable_frames;
    _Atomic uint_fast32_t published_minimum_fifo_fill_frames;
    _Atomic uint_fast32_t published_maximum_fifo_fill_frames;
    _Atomic uint_fast64_t last_input_callback_host_time;
    _Atomic uint_fast64_t maximum_input_callback_host_time_gap;
    _Atomic uint_fast64_t last_output_callback_host_time;
    _Atomic uint_fast64_t maximum_output_callback_host_time_gap;
    _Atomic uint_fast64_t maximum_input_callback_execution_host_time;
    _Atomic uint_fast64_t maximum_output_callback_execution_host_time;
    _Atomic uint_fast64_t playback_rate_bits;
    _Atomic uint_fast64_t minimum_playback_rate_bits;
    _Atomic uint_fast64_t maximum_playback_rate_bits;
    _Atomic uint_fast64_t maximum_playback_rate_deviation_bits;
    _Atomic int_fast32_t last_input_status;
    _Atomic int_fast32_t last_output_status;
};

static double ScreamBarClamp(double value, double minimum, double maximum) {
    return fmin(fmax(value, minimum), maximum);
}

static uint_fast64_t ScreamBarDoubleBits(double value) {
    uint_fast64_t bits = 0;
    memcpy(&bits, &value, sizeof(value));
    return bits;
}

static double ScreamBarDoubleFromBits(uint_fast64_t bits) {
    double value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void ScreamBarStoreMaximumDouble(
    _Atomic uint_fast64_t *maximum_value_bits,
    double candidate
) {
    uint_fast64_t observed_bits = atomic_load_explicit(
        maximum_value_bits,
        memory_order_relaxed
    );
    while (ScreamBarDoubleFromBits(observed_bits) < candidate) {
        const uint_fast64_t candidate_bits = ScreamBarDoubleBits(candidate);
        if (atomic_compare_exchange_weak_explicit(
                maximum_value_bits,
                &observed_bits,
                candidate_bits,
                memory_order_relaxed,
                memory_order_relaxed
            )) {
            return;
        }
    }
}

/*
 * Output-callback telemetry has a single writer. Accumulation is plain local
 * storage; one versioned atomic snapshot is published every 64 callbacks.
 */
static void ScreamBarPublishTelemetry(ScreamBarAsyncSRCContext *context) {
    atomic_fetch_add_explicit(
        &context->published_telemetry_generation,
        1,
        memory_order_acq_rel
    );
    atomic_store_explicit(
        &context->published_fifo_fill_sample_count,
        context->fifo_fill_sample_count,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->published_fifo_fill_frame_sum,
        context->fifo_fill_frame_sum,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->published_playback_rate_adjustment_count,
        context->playback_rate_adjustment_count,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->published_minimum_fifo_fill_frames,
        context->minimum_fifo_fill_frames == UINT32_MAX
            ? 0
            : context->minimum_fifo_fill_frames,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->published_maximum_fifo_fill_frames,
        context->maximum_fifo_fill_frames,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->minimum_playback_rate_bits,
        ScreamBarDoubleBits(
            context->has_applied_playback_rate
                ? context->minimum_playback_rate
                : 0
        ),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->maximum_playback_rate_bits,
        ScreamBarDoubleBits(
            context->has_applied_playback_rate
                ? context->maximum_playback_rate
                : 0
        ),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->published_telemetry_saturated,
        context->telemetry_saturated,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &context->published_telemetry_generation,
        1,
        memory_order_release
    );
}

static void ScreamBarRecordFIFOFill(
    ScreamBarAsyncSRCContext *context,
    uint32_t readable_frames
) {
    if (context->fifo_fill_sample_count < UINT64_MAX
        && context->fifo_fill_frame_sum
            <= UINT64_MAX - (uint64_t)readable_frames) {
        context->fifo_fill_sample_count += 1;
        context->fifo_fill_frame_sum += readable_frames;
    } else {
        context->telemetry_saturated = true;
    }
    if (readable_frames < context->minimum_fifo_fill_frames) {
        context->minimum_fifo_fill_frames = readable_frames;
    }
    if (readable_frames > context->maximum_fifo_fill_frames) {
        context->maximum_fifo_fill_frames = readable_frames;
    }
}

static void ScreamBarRecordPlaybackRate(
    ScreamBarAsyncSRCContext *context,
    double playback_rate
) {
    if (fabs(playback_rate - context->last_applied_playback_rate)
            > SCREAM_BAR_PLAYBACK_RATE_DEADBAND) {
        context->last_applied_playback_rate = playback_rate;
        if (context->playback_rate_adjustment_count < UINT64_MAX) {
            context->playback_rate_adjustment_count += 1;
        } else {
            context->telemetry_saturated = true;
        }
    }
    if (!context->has_applied_playback_rate) {
        context->minimum_playback_rate = playback_rate;
        context->maximum_playback_rate = playback_rate;
        context->has_applied_playback_rate = true;
    } else if (playback_rate < context->minimum_playback_rate) {
        context->minimum_playback_rate = playback_rate;
    } else if (playback_rate > context->maximum_playback_rate) {
        context->maximum_playback_rate = playback_rate;
    }
}

static void ScreamBarCompleteOutputTelemetry(
    ScreamBarAsyncSRCContext *context
) {
    if (context->telemetry_callbacks_until_publish > 1) {
        context->telemetry_callbacks_until_publish -= 1;
        return;
    }
    ScreamBarPublishTelemetry(context);
    context->telemetry_callbacks_until_publish =
        SCREAM_BAR_TELEMETRY_PUBLISH_INTERVAL;
}

static void ScreamBarCopyPublishedTelemetry(
    const ScreamBarAsyncSRCContext *context,
    ScreamBarAsyncSRCMetrics *metrics
) {
    for (;;) {
        const uint_fast64_t generation_before = atomic_load_explicit(
            &context->published_telemetry_generation,
            memory_order_acquire
        );
        if ((generation_before & 1U) != 0) {
            continue;
        }
        const uint64_t fifo_fill_sample_count = atomic_load_explicit(
            &context->published_fifo_fill_sample_count,
            memory_order_relaxed
        );
        const uint64_t fifo_fill_frame_sum = atomic_load_explicit(
            &context->published_fifo_fill_frame_sum,
            memory_order_relaxed
        );
        const uint64_t playback_rate_adjustment_count = atomic_load_explicit(
            &context->published_playback_rate_adjustment_count,
            memory_order_relaxed
        );
        const uint32_t minimum_fifo_fill_frames = (uint32_t)atomic_load_explicit(
            &context->published_minimum_fifo_fill_frames,
            memory_order_relaxed
        );
        const uint32_t maximum_fifo_fill_frames = (uint32_t)atomic_load_explicit(
            &context->published_maximum_fifo_fill_frames,
            memory_order_relaxed
        );
        const double minimum_playback_rate = ScreamBarDoubleFromBits(
            atomic_load_explicit(
                &context->minimum_playback_rate_bits,
                memory_order_relaxed
            )
        );
        const double maximum_playback_rate = ScreamBarDoubleFromBits(
            atomic_load_explicit(
                &context->maximum_playback_rate_bits,
                memory_order_relaxed
            )
        );
        const bool telemetry_saturated = atomic_load_explicit(
            &context->published_telemetry_saturated,
            memory_order_relaxed
        );
        atomic_thread_fence(memory_order_acquire);
        const uint_fast64_t generation_after = atomic_load_explicit(
            &context->published_telemetry_generation,
            memory_order_relaxed
        );
        if (generation_before == generation_after) {
            metrics->fifo_fill_sample_count = fifo_fill_sample_count;
            metrics->fifo_fill_frame_sum = fifo_fill_frame_sum;
            metrics->playback_rate_adjustment_count =
                playback_rate_adjustment_count;
            metrics->minimum_fifo_fill_frames = minimum_fifo_fill_frames;
            metrics->maximum_fifo_fill_frames = maximum_fifo_fill_frames;
            metrics->minimum_playback_rate = minimum_playback_rate;
            metrics->maximum_playback_rate = maximum_playback_rate;
            metrics->telemetry_saturated = telemetry_saturated;
            return;
        }
    }
}

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

static void ScreamBarStoreMaximum(
    _Atomic uint_fast32_t *maximum_value,
    uint32_t candidate
) {
    uint_fast32_t observed = atomic_load_explicit(
        maximum_value,
        memory_order_relaxed
    );
    while (observed < candidate
           && !atomic_compare_exchange_weak_explicit(
               maximum_value,
               &observed,
               candidate,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
}

static void ScreamBarStoreMaximum64(
    _Atomic uint_fast64_t *maximum_value,
    uint64_t candidate
) {
    uint_fast64_t observed = atomic_load_explicit(
        maximum_value,
        memory_order_relaxed
    );
    while (observed < candidate
           && !atomic_compare_exchange_weak_explicit(
               maximum_value,
               &observed,
               candidate,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
}

static void ScreamBarRecordCallbackHostTime(
    const AudioTimeStamp *timestamp,
    _Atomic uint_fast64_t *last_callback_host_time,
    _Atomic uint_fast64_t *maximum_callback_host_time_gap
) {
    if (timestamp == NULL
        || (timestamp->mFlags & kAudioTimeStampHostTimeValid) == 0) {
        return;
    }
    const uint_fast64_t previous_host_time = atomic_exchange_explicit(
        last_callback_host_time,
        timestamp->mHostTime,
        memory_order_relaxed
    );
    if (previous_host_time > 0 && timestamp->mHostTime > previous_host_time) {
        ScreamBarStoreMaximum64(
            maximum_callback_host_time_gap,
            timestamp->mHostTime - previous_host_time
        );
    }
}

static void ScreamBarRecordCallbackExecutionTime(
    uint64_t start_host_time,
    uint32_t frame_count,
    double deadline_host_ticks_per_frame,
    _Atomic uint_fast64_t *maximum_execution_host_time,
    _Atomic uint_fast64_t *deadline_miss_count
) {
    const uint64_t end_host_time = AudioGetCurrentHostTime();
    if (end_host_time >= start_host_time) {
        const uint64_t execution_host_time = end_host_time - start_host_time;
        ScreamBarStoreMaximum64(
            maximum_execution_host_time,
            execution_host_time
        );
        if (frame_count > 0
            && deadline_host_ticks_per_frame > 0
            && isfinite(deadline_host_ticks_per_frame)) {
            const double deadline_host_time =
                (double)frame_count * deadline_host_ticks_per_frame;
            if ((double)execution_host_time >= deadline_host_time) {
                atomic_fetch_add_explicit(
                    deadline_miss_count,
                    1,
                    memory_order_relaxed
                );
            }
        }
    }
}

static void ScreamBarMarkOutputSilent(
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
    for (uint32_t buffer_index = 0;
         buffer_index < output_data->mNumberBuffers;
         ++buffer_index) {
        AudioBuffer *buffer = &output_data->mBuffers[buffer_index];
        if (buffer->mData == NULL) {
            continue;
        }
        const uint64_t requested_bytes =
            (uint64_t)frame_count * buffer->mNumberChannels * sizeof(Float32);
        const uint32_t bytes_to_clear = requested_bytes < buffer->mDataByteSize
            ? (uint32_t)requested_bytes
            : buffer->mDataByteSize;
        memset(buffer->mData, 0, bytes_to_clear);
        buffer->mDataByteSize = bytes_to_clear;
    }
}

ScreamBarAsyncSRCClockController *ScreamBarAsyncSRCClockControllerCreate(void) {
    return calloc(1, sizeof(ScreamBarAsyncSRCClockController));
}

void ScreamBarAsyncSRCClockControllerDestroy(
    ScreamBarAsyncSRCClockController *controller
) {
    free(controller);
}

void ScreamBarAsyncSRCClockControllerReset(
    ScreamBarAsyncSRCClockController *controller
) {
    if (controller != NULL) {
        controller->averaged_fill_error_frames = 0;
        controller->estimated_input_quantum_frames = 0;
        controller->previous_readable_frames = 0;
        controller->previous_source_frames = 0;
        controller->smoothed_playback_rate = 1.0;
        controller->adaptation_elapsed_seconds = 0;
        controller->locked_fill_error_frames = 0;
        controller->has_previous_observation = false;
        controller->playback_rate_locked = false;
    }
}

double ScreamBarAsyncSRCClockControllerUpdate(
    ScreamBarAsyncSRCClockController *controller,
    uint32_t readable_frames,
    uint32_t target_fill_frames,
    uint32_t output_frame_count,
    double fifo_sample_rate,
    double output_sample_rate,
    bool adaptive_clock_control
) {
    if (controller == NULL || target_fill_frames == 0
        || output_frame_count == 0
        || fifo_sample_rate <= 0 || !isfinite(fifo_sample_rate)
        || output_sample_rate <= 0 || !isfinite(output_sample_rate)) {
        return 1.0;
    }
    const double elapsed_seconds = output_frame_count / output_sample_rate;
    const double nominal_source_frames =
        output_frame_count * fifo_sample_rate / output_sample_rate;
    if (controller->has_previous_observation) {
        const double observed_arrival_frames = (double)readable_frames
            - controller->previous_readable_frames
            + controller->previous_source_frames;
        const double maximum_plausible_arrival_frames = fmax(
            output_frame_count,
            nominal_source_frames
        ) * 2.0;
        if (observed_arrival_frames >= 1.0
            && observed_arrival_frames <= maximum_plausible_arrival_frames) {
            if (controller->estimated_input_quantum_frames == 0
                || observed_arrival_frames
                    < controller->estimated_input_quantum_frames) {
                controller->estimated_input_quantum_frames =
                    observed_arrival_frames;
            } else {
                const double quantum_smoothing_factor = fmin(
                    1.0,
                    elapsed_seconds
                        / SCREAM_BAR_MINIMUM_FILL_ERROR_TIME_CONSTANT_SECONDS
                );
                controller->estimated_input_quantum_frames +=
                    (observed_arrival_frames
                        - controller->estimated_input_quantum_frames)
                        * quantum_smoothing_factor;
            }
        }
    }
    const double phase_reserve_frames = adaptive_clock_control
        ? controller->estimated_input_quantum_frames * 0.5
        : 0;
    const double effective_target_fill_frames =
        target_fill_frames + phase_reserve_frames;
    const double fill_error_frames =
        (double)readable_frames - effective_target_fill_frames;
    const double fill_error_time_constant_seconds = adaptive_clock_control
        ? fmax(
            SCREAM_BAR_MINIMUM_FILL_ERROR_TIME_CONSTANT_SECONDS,
            elapsed_seconds * SCREAM_BAR_CALLBACK_SMOOTHING_COUNT
        )
        : SCREAM_BAR_FALLBACK_FILL_ERROR_TIME_CONSTANT_SECONDS;
    const double smoothing_factor = 1.0 - exp(
        -elapsed_seconds / fill_error_time_constant_seconds
    );
    controller->averaged_fill_error_frames +=
        (fill_error_frames - controller->averaged_fill_error_frames)
            * smoothing_factor;
    const double fill_correction_seconds = adaptive_clock_control
        ? fmax(
            SCREAM_BAR_MINIMUM_FILL_CORRECTION_SECONDS,
            target_fill_frames / fifo_sample_rate
                * SCREAM_BAR_TARGET_CORRECTION_MULTIPLIER
        )
        : SCREAM_BAR_FALLBACK_FILL_CORRECTION_SECONDS;
    const double fill_correction = ScreamBarClamp(
        controller->averaged_fill_error_frames
            / (fifo_sample_rate * fill_correction_seconds),
        -SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION,
        SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION
    );
    const double requested_playback_rate = 1.0 + fill_correction;
    if (controller->smoothed_playback_rate == 0) {
        controller->smoothed_playback_rate = 1.0;
    }
    if (adaptive_clock_control && controller->playback_rate_locked) {
        const double unlock_fill_delta_frames = fmax(
            SCREAM_BAR_RATE_LOCK_MINIMUM_FILL_DELTA_FRAMES,
            controller->estimated_input_quantum_frames
                / SCREAM_BAR_RATE_LOCK_FILL_QUANTUM_DIVISOR
        );
        if (fabs(
                controller->averaged_fill_error_frames
                    - controller->locked_fill_error_frames
            ) > unlock_fill_delta_frames) {
            controller->playback_rate_locked = false;
            controller->adaptation_elapsed_seconds = 0;
        }
    }
    const double playback_rate_smoothing_factor = adaptive_clock_control
        ? 1.0 - exp(
            -elapsed_seconds / SCREAM_BAR_PLAYBACK_RATE_TIME_CONSTANT_SECONDS
        )
        : 1.0 - exp(
            -elapsed_seconds
                / SCREAM_BAR_FALLBACK_PLAYBACK_RATE_TIME_CONSTANT_SECONDS
        );
    const double playback_rate_delta = requested_playback_rate
        - controller->smoothed_playback_rate;
    if (!controller->playback_rate_locked
        && fabs(playback_rate_delta) > SCREAM_BAR_PLAYBACK_RATE_DEADBAND) {
        controller->smoothed_playback_rate += playback_rate_delta
            * playback_rate_smoothing_factor;
    }
    if (adaptive_clock_control && !controller->playback_rate_locked) {
        controller->adaptation_elapsed_seconds += elapsed_seconds;
        if (controller->adaptation_elapsed_seconds
                >= SCREAM_BAR_RATE_LOCK_SETTLING_SECONDS
            && fabs(
                requested_playback_rate - controller->smoothed_playback_rate
            ) <= SCREAM_BAR_RATE_LOCK_MAXIMUM_DELTA) {
            controller->playback_rate_locked = true;
            controller->locked_fill_error_frames =
                controller->averaged_fill_error_frames;
        }
    }
    const double playback_rate = controller->smoothed_playback_rate;
    controller->previous_readable_frames = readable_frames;
    controller->previous_source_frames = nominal_source_frames * playback_rate;
    controller->has_previous_observation = true;
    return playback_rate;
}

uint32_t ScreamBarAsyncSRCMaximumSourceFrames(
    uint32_t maximum_output_frames,
    double input_sample_rate,
    double output_sample_rate
) {
    if (maximum_output_frames == 0
        || input_sample_rate <= 0 || !isfinite(input_sample_rate)
        || output_sample_rate <= 0 || !isfinite(output_sample_rate)) {
        return 0;
    }
    const double required_frames = ceil(
        maximum_output_frames * input_sample_rate / output_sample_rate
            * (1.0 + SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION)
    ) + SCREAM_BAR_SOURCE_FRAME_MARGIN;
    if (!isfinite(required_frames) || required_frames > UINT32_MAX) {
        return 0;
    }
    return (uint32_t)required_frames;
}

double ScreamBarAsyncSRCMaximumPlaybackRateDeviation(void) {
    return SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION;
}

static ScreamBarAsyncSRCContext *ScreamBarAsyncSRCContextCreateInternal(
    AudioUnit input_audio_unit,
    AudioUnit varispeed_audio_unit,
    ScreamBarAsyncSRCInputRenderProc input_render_proc,
    void *input_render_context,
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
) {
    if ((input_audio_unit == NULL && input_render_proc == NULL)
        || varispeed_audio_unit == NULL
        || input_channel_count == 0 || output_channel_count == 0
        || maximum_input_frames == 0 || maximum_output_frames == 0
        || target_fill_frames == 0 || target_fill_frames >= ring_capacity_frames
        || maximum_target_fill_frames < target_fill_frames
        || maximum_target_fill_frames >= ring_capacity_frames
        || maximum_readable_frames < maximum_target_fill_frames
        || maximum_readable_frames >= ring_capacity_frames
        || input_sample_rate <= 0 || output_sample_rate <= 0) {
        return NULL;
    }
    const double host_clock_frequency = AudioGetHostClockFrequency();
    if (host_clock_frequency <= 0 || !isfinite(host_clock_frequency)) {
        return NULL;
    }

    ScreamBarAsyncSRCContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }
    context->input_audio_unit = input_audio_unit;
    context->varispeed_audio_unit = varispeed_audio_unit;
    context->input_render_proc = input_render_proc;
    context->input_render_context = input_render_context;
    context->input_channel_count = input_channel_count;
    context->output_channel_count = output_channel_count;
    context->maximum_input_frames = maximum_input_frames;
    context->maximum_output_frames = maximum_output_frames;
    context->ring_capacity_frames = ring_capacity_frames;
    context->initial_target_fill_frames = target_fill_frames;
    context->maximum_target_fill_frames = maximum_target_fill_frames;
    context->maximum_readable_frames = maximum_readable_frames;
    context->input_sample_rate = input_sample_rate;
    context->output_sample_rate = output_sample_rate;
    context->input_callback_deadline_host_ticks_per_frame =
        host_clock_frequency / input_sample_rate;
    context->output_callback_deadline_host_ticks_per_frame =
        host_clock_frequency / output_sample_rate;
    context->low_latency = low_latency;
    context->adaptive_clock_control = adaptive_clock_control;
    context->minimum_fifo_fill_frames = UINT32_MAX;
    context->last_applied_playback_rate = 1.0;
    context->telemetry_callbacks_until_publish =
        SCREAM_BAR_TELEMETRY_PUBLISH_INTERVAL;

    context->maximum_source_frames = ScreamBarAsyncSRCMaximumSourceFrames(
        maximum_output_frames,
        input_sample_rate,
        output_sample_rate
    );
    if (context->maximum_source_frames == 0) {
        ScreamBarAsyncSRCContextDestroy(context);
        return NULL;
    }

    context->ring_buffer = ScreamBarSPSCRingBufferCreate(
        output_channel_count,
        ring_capacity_frames
    );
    context->clock_controller = ScreamBarAsyncSRCClockControllerCreate();
    const size_t input_buffer_list_size = ScreamBarAudioBufferListSize(
        input_channel_count
    );
    if (input_buffer_list_size == 0) {
        ScreamBarAsyncSRCContextDestroy(context);
        return NULL;
    }
    context->input_buffer_list = calloc(1, input_buffer_list_size);
    if ((size_t)maximum_input_frames > SIZE_MAX / input_channel_count
        || (size_t)maximum_input_frames * input_channel_count
            > SIZE_MAX / sizeof(Float32)
        || (size_t)context->maximum_source_frames > SIZE_MAX / output_channel_count
        || (size_t)context->maximum_source_frames * output_channel_count
            > SIZE_MAX / sizeof(Float32)) {
        ScreamBarAsyncSRCContextDestroy(context);
        return NULL;
    }
    context->input_samples = calloc(
        (size_t)maximum_input_frames * input_channel_count,
        sizeof(Float32)
    );
    context->source_samples = calloc(
        (size_t)context->maximum_source_frames * output_channel_count,
        sizeof(Float32)
    );
    if (context->ring_buffer == NULL || context->clock_controller == NULL
        || context->input_buffer_list == NULL || context->input_samples == NULL
        || context->source_samples == NULL) {
        ScreamBarAsyncSRCContextDestroy(context);
        return NULL;
    }

    context->input_buffer_list->mNumberBuffers = input_channel_count;
    for (uint32_t channel = 0; channel < input_channel_count; ++channel) {
        context->input_buffer_list->mBuffers[channel].mNumberChannels = 1;
        context->input_buffer_list->mBuffers[channel].mData =
            context->input_samples + (size_t)channel * maximum_input_frames;
        context->input_buffer_list->mBuffers[channel].mDataByteSize =
            maximum_input_frames * sizeof(Float32);
    }

    atomic_init(&context->primed, false);
    atomic_init(&context->captured_frames, 0);
    atomic_init(&context->rendered_frames, 0);
    atomic_init(&context->priming_silence_frames, 0);
    atomic_init(&context->dropped_input_frames, 0);
    atomic_init(&context->underrun_count, 0);
    atomic_init(&context->latency_ceiling_underrun_count, 0);
    atomic_init(&context->overflow_count, 0);
    atomic_init(&context->resynchronization_count, 0);
    atomic_init(&context->startup_trim_count, 0);
    atomic_init(&context->startup_trimmed_frames, 0);
    atomic_init(&context->input_render_error_count, 0);
    atomic_init(&context->output_render_error_count, 0);
    atomic_init(&context->rate_parameter_error_count, 0);
    atomic_init(&context->input_callback_deadline_miss_count, 0);
    atomic_init(&context->output_callback_deadline_miss_count, 0);
    atomic_init(&context->published_fifo_fill_sample_count, 0);
    atomic_init(&context->published_fifo_fill_frame_sum, 0);
    atomic_init(&context->published_playback_rate_adjustment_count, 0);
    atomic_init(&context->published_telemetry_generation, 0);
    atomic_init(&context->published_telemetry_saturated, false);
    atomic_init(&context->latency_ceiling_overflow_count, 0);
    atomic_init(&context->input_callback_frame_limit_exceeded_count, 0);
    atomic_init(&context->output_callback_frame_limit_exceeded_count, 0);
    atomic_init(&context->target_fill_frames, target_fill_frames);
    atomic_init(&context->maximum_input_callback_frames, 0);
    atomic_init(&context->maximum_output_callback_frames, 0);
    atomic_init(&context->maximum_source_callback_frames, 0);
    atomic_init(&context->source_frames_for_current_output_callback, 0);
    atomic_init(&context->maximum_source_frames_per_output_callback, 0);
    atomic_init(&context->last_source_requested_frames, 0);
    atomic_init(&context->last_source_readable_frames, 0);
    atomic_init(&context->underrun_source_requested_frames, 0);
    atomic_init(&context->underrun_source_readable_frames, 0);
    atomic_init(&context->published_minimum_fifo_fill_frames, 0);
    atomic_init(&context->published_maximum_fifo_fill_frames, 0);
    atomic_init(&context->last_input_callback_host_time, 0);
    atomic_init(&context->maximum_input_callback_host_time_gap, 0);
    atomic_init(&context->last_output_callback_host_time, 0);
    atomic_init(&context->maximum_output_callback_host_time_gap, 0);
    atomic_init(&context->maximum_input_callback_execution_host_time, 0);
    atomic_init(&context->maximum_output_callback_execution_host_time, 0);
    atomic_init(&context->playback_rate_bits, ScreamBarDoubleBits(1.0));
    atomic_init(
        &context->minimum_playback_rate_bits,
        ScreamBarDoubleBits(0)
    );
    atomic_init(
        &context->maximum_playback_rate_bits,
        ScreamBarDoubleBits(0)
    );
    atomic_init(
        &context->maximum_playback_rate_deviation_bits,
        ScreamBarDoubleBits(0)
    );
    atomic_init(&context->last_input_status, noErr);
    atomic_init(&context->last_output_status, noErr);
    return context;
}

ScreamBarAsyncSRCContext *ScreamBarAsyncSRCContextCreate(
    AudioUnit input_audio_unit,
    AudioUnit varispeed_audio_unit,
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
) {
    return ScreamBarAsyncSRCContextCreateInternal(
        input_audio_unit,
        varispeed_audio_unit,
        NULL,
        NULL,
        input_channel_count,
        output_channel_count,
        maximum_input_frames,
        maximum_output_frames,
        ring_capacity_frames,
        target_fill_frames,
        maximum_target_fill_frames,
        maximum_readable_frames,
        input_sample_rate,
        output_sample_rate,
        low_latency,
        adaptive_clock_control
    );
}

ScreamBarAsyncSRCContext *ScreamBarAsyncSRCContextCreateWithInputRenderProc(
    ScreamBarAsyncSRCInputRenderProc input_render_proc,
    void *input_render_context,
    AudioUnit varispeed_audio_unit,
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
) {
    return ScreamBarAsyncSRCContextCreateInternal(
        NULL,
        varispeed_audio_unit,
        input_render_proc,
        input_render_context,
        input_channel_count,
        output_channel_count,
        maximum_input_frames,
        maximum_output_frames,
        ring_capacity_frames,
        target_fill_frames,
        maximum_target_fill_frames,
        maximum_readable_frames,
        input_sample_rate,
        output_sample_rate,
        low_latency,
        adaptive_clock_control
    );
}

void ScreamBarAsyncSRCContextDestroy(ScreamBarAsyncSRCContext *context) {
    if (context == NULL) {
        return;
    }
    ScreamBarSPSCRingBufferDestroy(context->ring_buffer);
    ScreamBarAsyncSRCClockControllerDestroy(context->clock_controller);
    free(context->input_buffer_list);
    free(context->input_samples);
    free(context->source_samples);
    context->ring_buffer = NULL;
    context->clock_controller = NULL;
    context->input_buffer_list = NULL;
    context->input_samples = NULL;
    context->source_samples = NULL;
    free(context);
}

void ScreamBarAsyncSRCFlushMetrics(ScreamBarAsyncSRCContext *context) {
    if (context != NULL) {
        ScreamBarPublishTelemetry(context);
    }
}

void ScreamBarAsyncSRCCopyMetrics(
    const ScreamBarAsyncSRCContext *context,
    ScreamBarAsyncSRCMetrics *metrics
) {
    if (context == NULL || metrics == NULL) {
        return;
    }
    metrics->captured_frames = atomic_load_explicit(
        &context->captured_frames,
        memory_order_relaxed
    );
    metrics->rendered_frames = atomic_load_explicit(
        &context->rendered_frames,
        memory_order_relaxed
    );
    metrics->priming_silence_frames = atomic_load_explicit(
        &context->priming_silence_frames,
        memory_order_relaxed
    );
    metrics->dropped_input_frames = atomic_load_explicit(
        &context->dropped_input_frames,
        memory_order_relaxed
    );
    metrics->underrun_count = atomic_load_explicit(
        &context->underrun_count,
        memory_order_relaxed
    );
    metrics->latency_ceiling_underrun_count = atomic_load_explicit(
        &context->latency_ceiling_underrun_count,
        memory_order_relaxed
    );
    metrics->overflow_count = atomic_load_explicit(
        &context->overflow_count,
        memory_order_relaxed
    );
    metrics->resynchronization_count = atomic_load_explicit(
        &context->resynchronization_count,
        memory_order_relaxed
    );
    metrics->startup_trim_count = atomic_load_explicit(
        &context->startup_trim_count,
        memory_order_relaxed
    );
    metrics->startup_trimmed_frames = atomic_load_explicit(
        &context->startup_trimmed_frames,
        memory_order_relaxed
    );
    metrics->input_render_error_count = atomic_load_explicit(
        &context->input_render_error_count,
        memory_order_relaxed
    );
    metrics->output_render_error_count = atomic_load_explicit(
        &context->output_render_error_count,
        memory_order_relaxed
    );
    metrics->rate_parameter_error_count = atomic_load_explicit(
        &context->rate_parameter_error_count,
        memory_order_relaxed
    );
    metrics->input_callback_deadline_miss_count = atomic_load_explicit(
        &context->input_callback_deadline_miss_count,
        memory_order_relaxed
    );
    metrics->output_callback_deadline_miss_count = atomic_load_explicit(
        &context->output_callback_deadline_miss_count,
        memory_order_relaxed
    );
    ScreamBarCopyPublishedTelemetry(context, metrics);
    metrics->latency_ceiling_overflow_count = atomic_load_explicit(
        &context->latency_ceiling_overflow_count,
        memory_order_relaxed
    );
    metrics->input_callback_frame_limit_exceeded_count = atomic_load_explicit(
        &context->input_callback_frame_limit_exceeded_count,
        memory_order_relaxed
    );
    metrics->output_callback_frame_limit_exceeded_count = atomic_load_explicit(
        &context->output_callback_frame_limit_exceeded_count,
        memory_order_relaxed
    );
    metrics->readable_frames = ScreamBarSPSCRingBufferReadableFrames(
        context->ring_buffer
    );
    metrics->target_fill_frames = (uint32_t)atomic_load_explicit(
        &context->target_fill_frames,
        memory_order_relaxed
    );
    metrics->maximum_target_fill_frames = context->maximum_target_fill_frames;
    metrics->ring_capacity_frames = context->ring_capacity_frames;
    metrics->maximum_input_callback_frames = (uint32_t)atomic_load_explicit(
        &context->maximum_input_callback_frames,
        memory_order_relaxed
    );
    metrics->maximum_output_callback_frames = (uint32_t)atomic_load_explicit(
        &context->maximum_output_callback_frames,
        memory_order_relaxed
    );
    metrics->maximum_source_callback_frames = (uint32_t)atomic_load_explicit(
        &context->maximum_source_callback_frames,
        memory_order_relaxed
    );
    metrics->maximum_source_frames_per_output_callback =
        (uint32_t)atomic_load_explicit(
            &context->maximum_source_frames_per_output_callback,
            memory_order_relaxed
        );
    metrics->last_source_requested_frames = (uint32_t)atomic_load_explicit(
        &context->last_source_requested_frames,
        memory_order_relaxed
    );
    metrics->last_source_readable_frames = (uint32_t)atomic_load_explicit(
        &context->last_source_readable_frames,
        memory_order_relaxed
    );
    metrics->underrun_source_requested_frames = (uint32_t)atomic_load_explicit(
        &context->underrun_source_requested_frames,
        memory_order_relaxed
    );
    metrics->underrun_source_readable_frames = (uint32_t)atomic_load_explicit(
        &context->underrun_source_readable_frames,
        memory_order_relaxed
    );
    metrics->maximum_input_callback_host_time_gap = atomic_load_explicit(
        &context->maximum_input_callback_host_time_gap,
        memory_order_relaxed
    );
    metrics->maximum_output_callback_host_time_gap = atomic_load_explicit(
        &context->maximum_output_callback_host_time_gap,
        memory_order_relaxed
    );
    metrics->maximum_input_callback_execution_host_time = atomic_load_explicit(
        &context->maximum_input_callback_execution_host_time,
        memory_order_relaxed
    );
    metrics->maximum_output_callback_execution_host_time = atomic_load_explicit(
        &context->maximum_output_callback_execution_host_time,
        memory_order_relaxed
    );
    metrics->playback_rate = ScreamBarDoubleFromBits(
        atomic_load_explicit(&context->playback_rate_bits, memory_order_relaxed)
    );
    metrics->maximum_playback_rate_deviation = ScreamBarDoubleFromBits(
        atomic_load_explicit(
            &context->maximum_playback_rate_deviation_bits,
            memory_order_relaxed
        )
    );
    metrics->last_input_status = (OSStatus)atomic_load_explicit(
        &context->last_input_status,
        memory_order_relaxed
    );
    metrics->last_output_status = (OSStatus)atomic_load_explicit(
        &context->last_output_status,
        memory_order_relaxed
    );
}

OSStatus ScreamBarAsyncSRCInputCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)bus_number;
    (void)output_data;
    ScreamBarAsyncSRCContext *context = reference_context;
    if (context == NULL) {
        return kAudio_ParamError;
    }
    const uint64_t callback_start_host_time = AudioGetCurrentHostTime();
    ScreamBarRecordCallbackHostTime(
        timestamp,
        &context->last_input_callback_host_time,
        &context->maximum_input_callback_host_time_gap
    );
    if (timestamp == NULL) {
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->input_callback_deadline_host_ticks_per_frame,
            &context->maximum_input_callback_execution_host_time,
            &context->input_callback_deadline_miss_count
        );
        return kAudio_ParamError;
    }
    if (frame_count > context->maximum_input_frames) {
        atomic_fetch_add_explicit(
            &context->input_callback_frame_limit_exceeded_count,
            1,
            memory_order_relaxed
        );
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->input_callback_deadline_host_ticks_per_frame,
            &context->maximum_input_callback_execution_host_time,
            &context->input_callback_deadline_miss_count
        );
        return kAudio_ParamError;
    }
    ScreamBarStoreMaximum(&context->maximum_input_callback_frames, frame_count);
    for (uint32_t channel = 0;
         channel < context->input_channel_count;
         ++channel) {
        context->input_buffer_list->mBuffers[channel].mDataByteSize =
            frame_count * sizeof(Float32);
    }
    const OSStatus status = context->input_render_proc != NULL
        ? context->input_render_proc(
            context->input_render_context,
            action_flags,
            timestamp,
            1,
            frame_count,
            context->input_buffer_list
        )
        : AudioUnitRender(
            context->input_audio_unit,
            action_flags,
            timestamp,
            1,
            frame_count,
            context->input_buffer_list
        );
    atomic_store_explicit(&context->last_input_status, status, memory_order_relaxed);
    if (status != noErr) {
        atomic_fetch_add_explicit(
            &context->input_render_error_count,
            1,
            memory_order_relaxed
        );
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->input_callback_deadline_host_ticks_per_frame,
            &context->maximum_input_callback_execution_host_time,
            &context->input_callback_deadline_miss_count
        );
        return noErr;
    }

    const uint32_t readable_before_input = ScreamBarSPSCRingBufferReadableFrames(
        context->ring_buffer
    );
    const uint32_t frames_available_below_ceiling = readable_before_input
            < context->maximum_readable_frames
        ? context->maximum_readable_frames - readable_before_input
        : 0;
    const uint32_t frames_to_write = frame_count < frames_available_below_ceiling
        ? frame_count
        : frames_available_below_ceiling;
    const uint32_t written_frames = ScreamBarSPSCRingBufferWriteMappedPlanar(
        context->ring_buffer,
        context->input_buffer_list,
        context->input_channel_count,
        frames_to_write
    );
    atomic_fetch_add_explicit(
        &context->captured_frames,
        written_frames,
        memory_order_relaxed
    );
    if (frames_to_write < frame_count) {
        atomic_fetch_add_explicit(
            &context->latency_ceiling_overflow_count,
            1,
            memory_order_relaxed
        );
    }
    if (written_frames < frames_to_write) {
        atomic_fetch_add_explicit(&context->overflow_count, 1, memory_order_relaxed);
    }
    if (written_frames < frame_count) {
        atomic_fetch_add_explicit(
            &context->dropped_input_frames,
            frame_count - written_frames,
            memory_order_relaxed
        );
    }
    ScreamBarRecordCallbackExecutionTime(
        callback_start_host_time,
        frame_count,
        context->input_callback_deadline_host_ticks_per_frame,
        &context->maximum_input_callback_execution_host_time,
        &context->input_callback_deadline_miss_count
    );
    return noErr;
}

OSStatus ScreamBarAsyncSRCSourceCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)action_flags;
    (void)timestamp;
    (void)bus_number;
    ScreamBarAsyncSRCContext *context = reference_context;
    if (context == NULL || output_data == NULL
        || frame_count > context->maximum_source_frames) {
        return kAudio_ParamError;
    }
    ScreamBarStoreMaximum(&context->maximum_source_callback_frames, frame_count);
    atomic_fetch_add_explicit(
        &context->source_frames_for_current_output_callback,
        frame_count,
        memory_order_relaxed
    );
    const uint32_t readable_before_source = ScreamBarSPSCRingBufferReadableFrames(
        context->ring_buffer
    );
    atomic_store_explicit(
        &context->last_source_requested_frames,
        frame_count,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->last_source_readable_frames,
        readable_before_source,
        memory_order_relaxed
    );

    if (output_data->mNumberBuffers < context->output_channel_count) {
        return kAudio_ParamError;
    }
    const uint32_t read_frames = ScreamBarSPSCRingBufferReadPlanar(
        context->ring_buffer,
        context->source_samples,
        context->output_channel_count,
        context->maximum_source_frames,
        frame_count
    );
    if (read_frames < frame_count) {
        atomic_store_explicit(
            &context->underrun_source_requested_frames,
            frame_count,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &context->underrun_source_readable_frames,
            readable_before_source,
            memory_order_relaxed
        );
        for (uint32_t channel = 0;
             channel < context->output_channel_count;
             ++channel) {
            Float32 *channel_samples = context->source_samples
                + (size_t)channel * context->maximum_source_frames;
            memset(
                channel_samples + read_frames,
                0,
                (size_t)(frame_count - read_frames) * sizeof(Float32)
            );
        }
        atomic_fetch_add_explicit(&context->underrun_count, 1, memory_order_relaxed);
        atomic_store_explicit(&context->primed, false, memory_order_release);

        const uint32_t current_target = (uint32_t)atomic_load_explicit(
            &context->target_fill_frames,
            memory_order_relaxed
        );
        if (current_target >= context->maximum_target_fill_frames) {
            atomic_fetch_add_explicit(
                &context->latency_ceiling_underrun_count,
                1,
                memory_order_relaxed
            );
        }
        const uint32_t recovery_step = frame_count > current_target
            ? frame_count
            : current_target;
        const uint32_t maximum_target = context->maximum_target_fill_frames;
        const uint32_t remaining_target_capacity = maximum_target > current_target
            ? maximum_target - current_target
            : 0;
        const uint32_t increased_target = recovery_step >= remaining_target_capacity
            ? maximum_target
            : current_target + recovery_step;
        atomic_store_explicit(
            &context->target_fill_frames,
            increased_target,
            memory_order_relaxed
        );
        context->stable_output_frames = 0;
        ScreamBarAsyncSRCClockControllerReset(context->clock_controller);
    }

    output_data->mNumberBuffers = context->output_channel_count;
    for (uint32_t channel = 0;
         channel < context->output_channel_count;
         ++channel) {
        output_data->mBuffers[channel].mNumberChannels = 1;
        output_data->mBuffers[channel].mDataByteSize =
            frame_count * sizeof(Float32);
        output_data->mBuffers[channel].mData = context->source_samples
            + (size_t)channel * context->maximum_source_frames;
    }
    return noErr;
}

OSStatus ScreamBarAsyncSRCOutputCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)bus_number;
    ScreamBarAsyncSRCContext *context = reference_context;
    if (context == NULL) {
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        return noErr;
    }
    const uint64_t callback_start_host_time = AudioGetCurrentHostTime();
    ScreamBarRecordCallbackHostTime(
        timestamp,
        &context->last_output_callback_host_time,
        &context->maximum_output_callback_host_time_gap
    );
    if (frame_count > context->maximum_output_frames) {
        atomic_fetch_add_explicit(
            &context->output_callback_frame_limit_exceeded_count,
            1,
            memory_order_relaxed
        );
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->output_callback_deadline_host_ticks_per_frame,
            &context->maximum_output_callback_execution_host_time,
            &context->output_callback_deadline_miss_count
        );
        return noErr;
    }
    if (timestamp == NULL || output_data == NULL) {
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->output_callback_deadline_host_ticks_per_frame,
            &context->maximum_output_callback_execution_host_time,
            &context->output_callback_deadline_miss_count
        );
        return noErr;
    }
    ScreamBarStoreMaximum(&context->maximum_output_callback_frames, frame_count);

    uint32_t readable_frames = ScreamBarSPSCRingBufferReadableFrames(
        context->ring_buffer
    );
    ScreamBarRecordFIFOFill(context, readable_frames);
    uint32_t target_fill_frames = (uint32_t)atomic_load_explicit(
        &context->target_fill_frames,
        memory_order_relaxed
    );
    const uint32_t observed_input_quantum = (uint32_t)atomic_load_explicit(
        &context->maximum_input_callback_frames,
        memory_order_relaxed
    );
    const uint32_t high_water_mark = context->maximum_readable_frames;
    bool primed = atomic_load_explicit(&context->primed, memory_order_acquire);
    if (readable_frames > high_water_mark && readable_frames > target_fill_frames) {
        const uint32_t discarded_frames = readable_frames - target_fill_frames;
        const uint32_t actually_discarded_frames =
            ScreamBarSPSCRingBufferDiscard(
                context->ring_buffer,
                discarded_frames
            );
        if (primed) {
            atomic_fetch_add_explicit(
                &context->resynchronization_count,
                1,
                memory_order_relaxed
            );
        } else {
            atomic_fetch_add_explicit(
                &context->startup_trim_count,
                1,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &context->startup_trimmed_frames,
                actually_discarded_frames,
                memory_order_relaxed
            );
        }
        atomic_store_explicit(&context->primed, false, memory_order_release);
        primed = false;
        readable_frames -= actually_discarded_frames;
    }

    if (!primed) {
        const uint32_t priming_margin = observed_input_quantum / 2U;
        const uint32_t maximum_priming_target =
            context->maximum_target_fill_frames;
        const uint32_t priming_target =
            priming_margin >= maximum_priming_target - target_fill_frames
                ? maximum_priming_target
                : target_fill_frames + priming_margin;
        if (readable_frames < priming_target) {
            ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
            atomic_fetch_add_explicit(
                &context->priming_silence_frames,
                frame_count,
                memory_order_relaxed
            );
            ScreamBarCompleteOutputTelemetry(context);
            ScreamBarRecordCallbackExecutionTime(
                callback_start_host_time,
                frame_count,
                context->output_callback_deadline_host_ticks_per_frame,
                &context->maximum_output_callback_execution_host_time,
                &context->output_callback_deadline_miss_count
            );
            return noErr;
        }
        atomic_store_explicit(&context->primed, true, memory_order_release);
    }

    if (context->low_latency
        && target_fill_frames < context->maximum_target_fill_frames) {
        const uint32_t nominal_source_frames = (uint32_t)ceil(
            frame_count * context->input_sample_rate
                / context->output_sample_rate
                * (1.0 + SCREAM_BAR_MAXIMUM_PLAYBACK_RATE_DEVIATION)
        );
        const uint32_t low_water_guard_frames =
            observed_input_quantum / SCREAM_BAR_LOW_WATER_GUARD_DIVISOR;
        const uint64_t low_water_mark =
            (uint64_t)nominal_source_frames + low_water_guard_frames;
        if ((uint64_t)readable_frames < low_water_mark) {
            const uint32_t observed_target_growth =
                observed_input_quantum / SCREAM_BAR_TARGET_GROWTH_DIVISOR;
            const uint32_t target_growth_frames = observed_target_growth > 0
                ? observed_target_growth
                : 1;
            const uint32_t remaining_target_capacity =
                context->maximum_target_fill_frames - target_fill_frames;
            target_fill_frames += target_growth_frames
                    < remaining_target_capacity
                ? target_growth_frames
                : remaining_target_capacity;
            atomic_store_explicit(
                &context->target_fill_frames,
                target_fill_frames,
                memory_order_relaxed
            );
            context->stable_output_frames = 0;
        }
    }

    const double playback_rate = ScreamBarAsyncSRCClockControllerUpdate(
        context->clock_controller,
        readable_frames,
        target_fill_frames,
        frame_count,
        context->input_sample_rate,
        context->output_sample_rate,
        context->adaptive_clock_control
    );
    const OSStatus parameter_status = AudioUnitSetParameter(
        context->varispeed_audio_unit,
        kVarispeedParam_PlaybackRate,
        kAudioUnitScope_Global,
        0,
        (AudioUnitParameterValue)playback_rate,
        0
    );
    if (parameter_status != noErr) {
        atomic_fetch_add_explicit(
            &context->rate_parameter_error_count,
            1,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &context->last_output_status,
            parameter_status,
            memory_order_relaxed
        );
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        ScreamBarCompleteOutputTelemetry(context);
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->output_callback_deadline_host_ticks_per_frame,
            &context->maximum_output_callback_execution_host_time,
            &context->output_callback_deadline_miss_count
        );
        return noErr;
    }
    atomic_store_explicit(
        &context->playback_rate_bits,
        ScreamBarDoubleBits(playback_rate),
        memory_order_relaxed
    );
    ScreamBarRecordPlaybackRate(context, playback_rate);
    ScreamBarStoreMaximumDouble(
        &context->maximum_playback_rate_deviation_bits,
        fabs(playback_rate - 1.0)
    );

    const uint_fast64_t underruns_before = atomic_load_explicit(
        &context->underrun_count,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &context->source_frames_for_current_output_callback,
        0,
        memory_order_relaxed
    );
    const OSStatus render_status = AudioUnitRender(
        context->varispeed_audio_unit,
        action_flags,
        timestamp,
        0,
        frame_count,
        output_data
    );
    const uint32_t source_frames_for_output = (uint32_t)atomic_load_explicit(
        &context->source_frames_for_current_output_callback,
        memory_order_relaxed
    );
    ScreamBarStoreMaximum(
        &context->maximum_source_frames_per_output_callback,
        source_frames_for_output
    );
    atomic_store_explicit(
        &context->last_output_status,
        render_status,
        memory_order_relaxed
    );
    if (render_status != noErr) {
        atomic_fetch_add_explicit(
            &context->output_render_error_count,
            1,
            memory_order_relaxed
        );
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        ScreamBarCompleteOutputTelemetry(context);
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->output_callback_deadline_host_ticks_per_frame,
            &context->maximum_output_callback_execution_host_time,
            &context->output_callback_deadline_miss_count
        );
        return noErr;
    }

    atomic_fetch_add_explicit(
        &context->rendered_frames,
        frame_count,
        memory_order_relaxed
    );
    const uint_fast64_t underruns_after = atomic_load_explicit(
        &context->underrun_count,
        memory_order_relaxed
    );
    if (underruns_after != underruns_before) {
        ScreamBarMarkOutputSilent(action_flags, output_data, frame_count);
        ScreamBarCompleteOutputTelemetry(context);
        ScreamBarRecordCallbackExecutionTime(
            callback_start_host_time,
            frame_count,
            context->output_callback_deadline_host_ticks_per_frame,
            &context->maximum_output_callback_execution_host_time,
            &context->output_callback_deadline_miss_count
        );
        return noErr;
    }

    context->stable_output_frames += frame_count;
    const uint64_t stable_frame_threshold = (uint64_t)(
        context->output_sample_rate
            * SCREAM_BAR_STABLE_SECONDS_BEFORE_TARGET_REDUCTION
    );
    if (target_fill_frames > context->initial_target_fill_frames
        && context->stable_output_frames >= stable_frame_threshold) {
        const uint32_t reduction = (uint32_t)ceil(
            frame_count * context->input_sample_rate / context->output_sample_rate
        );
        target_fill_frames = target_fill_frames - context->initial_target_fill_frames
                > reduction
            ? target_fill_frames - reduction
            : context->initial_target_fill_frames;
        atomic_store_explicit(
            &context->target_fill_frames,
            target_fill_frames,
            memory_order_relaxed
        );
        context->stable_output_frames = 0;
    }
    ScreamBarCompleteOutputTelemetry(context);
    ScreamBarRecordCallbackExecutionTime(
        callback_start_host_time,
        frame_count,
        context->output_callback_deadline_host_ticks_per_frame,
        &context->maximum_output_callback_execution_host_time,
        &context->output_callback_deadline_miss_count
    );
    return noErr;
}
