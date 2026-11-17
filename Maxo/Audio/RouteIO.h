#ifndef MAXO_ROUTE_IO_H
#define MAXO_ROUTE_IO_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

typedef struct MaxoRouteIO MaxoRouteIO;

MaxoRouteIO * _Nullable MaxoRouteIOCreate(UInt32 tapBuffer, UInt32 leftChannel,
                                         UInt32 rightChannel, float gain, double sampleRate);
MaxoRouteIO * _Nullable MaxoRouteIOCreateMonitor(double sampleRate);
enum { MaxoWaveformCount = 32 };
void MaxoRouteIOCopyWaveform(const MaxoRouteIO * _Nonnull state, float * _Nonnull peaks);
uint32_t MaxoRouteIOActivity(const MaxoRouteIO * _Nonnull state);
void MaxoRouteIODestroy(MaxoRouteIO * _Nonnull state);
void MaxoRouteIOSetGain(MaxoRouteIO * _Nonnull state, float gain);
uint64_t MaxoRouteIOCycles(const MaxoRouteIO * _Nonnull state);
uint32_t MaxoRouteIOBeginMetering(MaxoRouteIO * _Nonnull state);
void MaxoRouteIOEndMetering(MaxoRouteIO * _Nonnull state);
double MaxoRouteIOMeasuredAmplitude(const MaxoRouteIO * _Nonnull state, uint32_t measurement);
OSStatus MaxoRouteIOUseTapOnly(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc,
                               UInt32 streamCount, UInt32 tapStream);
OSStatus MaxoRouteRender(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                         const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                         AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                         void * _Nullable context);

#endif
