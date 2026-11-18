#include "RouteIO.h"
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum { meterCapacity = 32 };

typedef struct {
    double b0, b1, b2, a1, a2;
} Biquad;

typedef struct {
    double z1, z2;
} FilterState;

typedef struct {
    _Atomic(uint32_t) requested;
    _Atomic(uint64_t) blocks[meterCapacity];
    uint32_t nextMeasurement;
    uint32_t activeMeasurement;
    UInt32 blockFrames;
    UInt32 frames;
    UInt32 blockCount;
    double energy;
    Biquad shelf, highPass;
    FilterState shelfState[2], highPassState[2];
} LoudnessMeter;

struct MaxoRouteIO {
    _Atomic(float) targetGain;
    _Atomic(uint64_t) cycles;
    float gain;
    float gainStep;
    // Peak limiter for Extra Loud: instant attack, smooth release, never above the ceiling.
    float limiterEnvelope;
    float limiterRelease;
    UInt32 tapBuffer;
    UInt32 leftChannel;
    UInt32 rightChannel;
    LoudnessMeter meter;
    bool monitorOnly;
    _Atomic(uint32_t) waveformIndex;
    _Atomic(uint32_t) activity;
    _Atomic(uint64_t) waveform[MaxoWaveformCount];
    UInt32 waveformFrames, waveformBinFrames;
    float inputPeak, outputPeak;
};

// Retune the BS.1770 K-weighting biquads from their 48 kHz reference coefficients.
static Biquad retune(Biquad filter, double rate) {
    double k = (48000 - rate) / (48000 + rate);
    double kSquared = k * k;
    double scale = 1 + filter.a1 * k + filter.a2 * kSquared;
    return (Biquad){
        (filter.b0 + filter.b1 * k + filter.b2 * kSquared) / scale,
        (2 * k * (filter.b0 + filter.b2) + (1 + kSquared) * filter.b1) / scale,
        (filter.b0 * kSquared + filter.b1 * k + filter.b2) / scale,
        (2 * k * (1 + filter.a2) + (1 + kSquared) * filter.a1) / scale,
        (kSquared + filter.a1 * k + filter.a2) / scale
    };
}

static double filterSample(Biquad filter, FilterState *state, double sample) {
    double output = filter.b0 * sample + state->z1;
    state->z1 = filter.b1 * sample - filter.a1 * output + state->z2;
    state->z2 = filter.b2 * sample - filter.a2 * output;
    return output;
}

static void meterSample(LoudnessMeter *meter, float left, float right) {
    double l = filterSample(meter->shelf, &meter->shelfState[0], left);
    double r = filterSample(meter->shelf, &meter->shelfState[1], right);
    l = filterSample(meter->highPass, &meter->highPassState[0], l);
    r = filterSample(meter->highPass, &meter->highPassState[1], r);
    meter->energy += l * l + r * r;
    if (++meter->frames == meter->blockFrames) {
        float power = (float)(meter->energy / meter->blockFrames);
        uint32_t bits;
        memcpy(&bits, &power, sizeof(bits));
        uint64_t block = ((uint64_t)meter->activeMeasurement << 32) | bits;
        atomic_store_explicit(&meter->blocks[meter->blockCount++], block, memory_order_relaxed);
        meter->frames = 0;
        meter->energy = 0;
    }
}

MaxoRouteIO *MaxoRouteIOCreate(UInt32 tapBuffer, UInt32 leftChannel, UInt32 rightChannel,
                               float gain, double sampleRate) {
    MaxoRouteIO *state = calloc(1, sizeof(*state));
    if (state != NULL) {
        atomic_init(&state->targetGain, gain);
        atomic_init(&state->cycles, 0);
        state->gain = gain;
        state->gainStep = 1.0f / (float)(sampleRate * 0.005);
        state->limiterRelease = (float)exp(-1.0 / (sampleRate * 0.15));
        state->tapBuffer = tapBuffer;
        state->leftChannel = leftChannel;
        state->rightChannel = rightChannel;
        state->waveformBinFrames = (UInt32)fmax(1, round(sampleRate * 0.018));
        atomic_init(&state->waveformIndex, 0);
        atomic_init(&state->activity, 0);
        for (UInt32 bin = 0; bin < MaxoWaveformCount; ++bin) {
            atomic_init(&state->waveform[bin], 0);
        }
        LoudnessMeter *meter = &state->meter;
        atomic_init(&meter->requested, 0);
        for (UInt32 block = 0; block < meterCapacity; ++block) {
            atomic_init(&meter->blocks[block], 0);
        }
        meter->blockFrames = (UInt32)fmax(1, round(sampleRate / 4));
        meter->shelf = retune((Biquad){1.53512485958697, -2.69169618940638, 1.19839281085285,
                                       -1.69065929318241, 0.73248077421585}, sampleRate);
        meter->highPass = retune((Biquad){1, -2, 1, -1.99004745483398, 0.99007225036621}, sampleRate);
    }
    return state;
}

MaxoRouteIO *MaxoRouteIOCreateMonitor(double sampleRate) {
    MaxoRouteIO *state = MaxoRouteIOCreate(0, 0, 1, 1, sampleRate);
    if (state) { state->monitorOnly = true; }
    return state;
}

uint32_t MaxoRouteIOActivity(const MaxoRouteIO *state) {
    return atomic_load_explicit(&state->activity, memory_order_relaxed);
}

void MaxoRouteIOCopyWaveform(const MaxoRouteIO *state, float *peaks) {
    uint32_t end = atomic_load_explicit(&state->waveformIndex, memory_order_acquire);
    for (UInt32 bin = 0; bin < MaxoWaveformCount; ++bin) {
        uint32_t index = end - MaxoWaveformCount + bin + 1;
        uint64_t entry = atomic_load_explicit(&state->waveform[index % MaxoWaveformCount], memory_order_relaxed);
        uint32_t bits = entry >> 32 == index ? (uint32_t)entry : 0;
        memcpy(&peaks[bin], &bits, sizeof(bits));
    }
}

static void waveformSample(MaxoRouteIO *state, float inputPeak, float outputPeak) {
    state->inputPeak = fmaxf(state->inputPeak, inputPeak);
    state->outputPeak = fmaxf(state->outputPeak, outputPeak);
    if (++state->waveformFrames < state->waveformBinFrames) { return; }
    uint32_t index = atomic_load_explicit(&state->waveformIndex, memory_order_relaxed) + 1;
    uint32_t bits;
    memcpy(&bits, &state->outputPeak, sizeof(bits));
    uint64_t entry = ((uint64_t)index << 32) | bits;
    atomic_store_explicit(&state->waveform[index % MaxoWaveformCount], entry, memory_order_relaxed);
    atomic_store_explicit(&state->waveformIndex, index, memory_order_release);
    if (state->inputPeak > 0.001f) {
        atomic_fetch_add_explicit(&state->activity, 1, memory_order_relaxed);
    }
    state->inputPeak = 0;
    state->outputPeak = 0;
    state->waveformFrames = 0;
}

void MaxoRouteIODestroy(MaxoRouteIO *state) {
    free(state);
}

void MaxoRouteIOSetGain(MaxoRouteIO *state, float gain) {
    atomic_store_explicit(&state->targetGain, gain, memory_order_relaxed);
}

uint64_t MaxoRouteIOCycles(const MaxoRouteIO *state) {
    return atomic_load_explicit(&state->cycles, memory_order_relaxed);
}

uint32_t MaxoRouteIOBeginMetering(MaxoRouteIO *state) {
    LoudnessMeter *meter = &state->meter;
    if (++meter->nextMeasurement == 0) { ++meter->nextMeasurement; }
    atomic_store_explicit(&meter->requested, meter->nextMeasurement, memory_order_relaxed);
    return meter->nextMeasurement;
}

void MaxoRouteIOEndMetering(MaxoRouteIO *state) {
    atomic_store_explicit(&state->meter.requested, 0, memory_order_relaxed);
}

double MaxoRouteIOMeasuredAmplitude(const MaxoRouteIO *state, uint32_t measurement) {
    if (!measurement) { return 0; }
    const LoudnessMeter *meter = &state->meter;
    double powers[meterCapacity];
    double sum = 0;
    UInt32 count = 0;
    for (UInt32 index = 0; index < meterCapacity; ++index) {
        uint64_t block = atomic_load_explicit(&meter->blocks[index], memory_order_relaxed);
        if (block >> 32 != measurement) { continue; }
        uint32_t bits = (uint32_t)block;
        float power;
        memcpy(&power, &bits, sizeof(power));
        if (isfinite(power) && power > 1e-6f) {
            powers[count++] = power;
            sum += power;
        }
    }
    // A notification or a short burst should not set the level for the whole mixer.
    const UInt32 minimumBlocks = 12;
    if (count < minimumBlocks) { return 0; }
    double gate = sum / count * 0.1;
    UInt32 accepted = 0;
    for (UInt32 index = 0; index < count; ++index) {
        if (powers[index] >= gate) {
            double power = powers[index];
            UInt32 position = accepted++;
            while (position && powers[position - 1] > power) {
                powers[position] = powers[position - 1];
                --position;
            }
            powers[position] = power;
        }
    }
    if (accepted < minimumBlocks) { return 0; }
    return sqrt((powers[(accepted - 1) / 2] + powers[accepted / 2]) * 0.5);
}

OSStatus MaxoRouteIOUseTapOnly(AudioObjectID device, AudioDeviceIOProcID proc,
                               UInt32 streamCount, UInt32 tapStream) {
    if (tapStream >= streamCount) {
        return kAudioHardwareIllegalOperationError;
    }
    UInt32 bytes = (UInt32)offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn)
                   + streamCount * (UInt32)sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (usage == NULL) {
        return kAudioHardwareUnspecifiedError;
    }
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = streamCount;
    // HAL's variable-length array extends past the struct's declared first entry.
    UInt32 *streams = (UInt32 *)((char *)usage + offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn));
    streams[tapStream] = 1;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage,
                                           kAudioDevicePropertyScopeInput,
                                           kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, bytes, usage);
    free(usage);
    return status;
}

typedef struct {
    float *samples;
    UInt32 stride;
    UInt32 frames;
} PCMChannel;

static PCMChannel channelAt(const AudioBufferList *list, UInt32 startBuffer, UInt32 channel) {
    for (UInt32 index = startBuffer; index < list->mNumberBuffers; ++index) {
        AudioBuffer buffer = list->mBuffers[index];
        if (channel < buffer.mNumberChannels) {
            if (buffer.mData == NULL) {
                break;
            }
            return (PCMChannel){
                (float *)buffer.mData + channel,
                buffer.mNumberChannels,
                buffer.mDataByteSize / sizeof(float) / buffer.mNumberChannels
            };
        }
        channel -= buffer.mNumberChannels;
    }
    return (PCMChannel){0};
}

static float sampleAt(PCMChannel channel, UInt32 index, UInt32 frames, float fraction) {
    float a = channel.samples[index * channel.stride];
    if (fraction == 0 || index + 1 >= frames) {
        return a;
    }
    float b = channel.samples[(index + 1) * channel.stride];
    return a + (b - a) * fraction;
}

OSStatus MaxoRouteRender(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    MaxoRouteIO *state = context;
    for (UInt32 index = 0; output && index < output->mNumberBuffers; ++index) {
        AudioBuffer buffer = output->mBuffers[index];
        if (buffer.mData) {
            memset(buffer.mData, 0, buffer.mDataByteSize);
        }
    }
    if (!state || !input || state->tapBuffer >= input->mNumberBuffers) {
        return noErr;
    }
    PCMChannel sourceLeft = channelAt(input, state->tapBuffer, 0);
    PCMChannel sourceRight = channelAt(input, state->tapBuffer, 1);
    bool forwards = !state->monitorOnly;
    if (forwards && !output) { return noErr; }
    PCMChannel left = forwards ? channelAt(output, 0, state->leftChannel) : sourceLeft;
    PCMChannel right = forwards ? channelAt(output, 0, state->rightChannel) : sourceRight;
    UInt32 sourceFrames = sourceLeft.frames < sourceRight.frames ? sourceLeft.frames : sourceRight.frames;
    UInt32 frames = left.frames < right.frames ? left.frames : right.frames;
    if (sourceFrames == 0 || frames == 0) {
        return noErr;
    }

    // The aggregate synchronizes the tap and output clocks. Devices can still expose
    // different frame counts for a cycle, such as a 48 kHz tap with a 44.1 kHz speaker.
    float ratio = (float)sourceFrames / (float)frames;
    bool mono = state->leftChannel == state->rightChannel;
    LoudnessMeter *meter = &state->meter;
    uint32_t measurement = atomic_load_explicit(&meter->requested, memory_order_relaxed);
    if (measurement && meter->activeMeasurement != measurement) {
        meter->activeMeasurement = measurement;
        meter->blockCount = 0;
        meter->frames = 0;
        meter->energy = 0;
        memset(meter->shelfState, 0, sizeof(meter->shelfState));
        memset(meter->highPassState, 0, sizeof(meter->highPassState));
    }
    float gain = state->gain;
    float target = atomic_load_explicit(&state->targetGain, memory_order_relaxed);
    float envelope = state->limiterEnvelope;
    const float limiterCeiling = 0.97f;
    for (UInt32 frame = 0; frame < frames; ++frame) {
        gain += fminf(state->gainStep, fmaxf(-state->gainStep, target - gain));
        float position = (float)frame * ratio;
        UInt32 index = (UInt32)position;
        if (index >= sourceFrames) index = sourceFrames - 1;
        float l = sampleAt(sourceLeft, index, sourceFrames, position - (float)index);
        float r = sampleAt(sourceRight, index, sourceFrames, position - (float)index);
        if (mono) { l = (l + r) * 0.5f; }
        float peak = fmaxf(fabsf(l), mono ? 0 : fabsf(r));
        // Gain above unity can push samples past full scale. The envelope follows the source
        // peak (instant attack, ~150 ms release) and caps the boost so the output stays under
        // the ceiling. Capping the gain rather than the output means a lower slider setting
        // takes effect at once, and the cap fades out smoothly as the gain returns to unity.
        envelope = fmaxf(peak, envelope * state->limiterRelease);
        float applied = gain;
        if (gain > 1.0f && envelope > 0.0f) {
            applied = fmaxf(1.0f, fminf(gain, limiterCeiling / envelope));
        }
        float outL = l * applied, outR = r * applied, outPeak = peak * applied;
        waveformSample(state, peak, outPeak);
        if (forwards) {
            left.samples[frame * left.stride] = outL;
            if (!mono) {
                right.samples[frame * right.stride] = outR;
            }
        }
        if (measurement && meter->blockCount < meterCapacity) {
            meterSample(meter, l, mono ? 0 : r);
        }
    }
    state->gain = gain;
    state->limiterEnvelope = envelope;
    atomic_fetch_add_explicit(&state->cycles, 1, memory_order_relaxed);
    return noErr;
}
