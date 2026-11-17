import CoreAudio
import Foundation

/// Owns a single application's tap and playback IO. All lifecycle calls run on the audio control queue.
final class PlaybackRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var renderState: OpaquePointer?
    private var startAttempted = false

    init(name: String, processes: [AudioObjectID], output: PlaybackDevice?, gain: Float) throws {
        do {
            try start(name: name, processes: processes, device: output, gain: gain)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    var cycles: UInt64 { renderState.map(MaxoRouteIOCycles) ?? 0 }
    var activity: UInt32 { renderState.map(MaxoRouteIOActivity) ?? 0 }

    func waveform() -> [Float] {
        guard let renderState else { return [] }
        var peaks = [Float](repeating: 0, count: Int(MaxoWaveformCount))
        MaxoRouteIOCopyWaveform(renderState, &peaks)
        return peaks
    }

    func setGain(_ gain: Float) {
        if let renderState { MaxoRouteIOSetGain(renderState, gain) }
    }

    func beginMetering() -> UInt32 { renderState.map(MaxoRouteIOBeginMetering) ?? 0 }

    func endMetering() {
        if let renderState { MaxoRouteIOEndMetering(renderState) }
    }

    func measuredAmplitude(_ measurement: UInt32) -> Double {
        renderState.map { MaxoRouteIOMeasuredAmplitude($0, measurement) } ?? 0
    }

    private func start(name: String, processes: [AudioObjectID], device: PlaybackDevice?, gain: Float) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Maxo · \(name)"
        description.isPrivate = true
        // Native playback resumes whenever the tap stops being read, including on startup failure.
        description.muteBehavior = device == nil ? .unmuted : .mutedWhenTapped
        try HALFailure.check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")
        let uid = HAL.string(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString

        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Maxo · \(name)",
            kAudioAggregateDeviceUIDKey: "com.maxo.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality
            ]],
        ]
        if let device {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = device.id
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: device.id]]
        }
        try HALFailure.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                             "Create playback device")

        // HAL appends the tap stream after the chosen device's own input streams.
        let physicalInputs = device.flatMap { HAL.channels($0.object, scope: HAL.input) } ?? []
        guard let inputs = HAL.channels(aggregate, scope: HAL.input),
              inputs == physicalInputs + [2] || inputs == physicalInputs + [1, 1],
              let inputStreams = HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: HAL.input),
              inputStreams.count == (device?.inputStreams.count ?? 0) + 1,
              let tapStream = inputStreams.last,
              let tapFormat = HAL.format(tapStream),
              Self.isFloatPCM(tapFormat),
              tapFormat.mChannelsPerFrame == 2 else {
            throw HALFailure(operation: "Prepare capture stream", status: kAudioDeviceUnsupportedFormatError)
        }
        let state: OpaquePointer?
        if let device {
            state = try makePlaybackState(device: device, inputBuffers: UInt32(physicalInputs.count), gain: gain)
        } else {
            state = MaxoRouteIOCreateMonitor(tapFormat.mSampleRate)
        }
        guard let state else {
            throw HALFailure(operation: "Allocate audio state", status: kAudioHardwareUnspecifiedError)
        }
        renderState = state
        try HALFailure.check(AudioDeviceCreateIOProcID(aggregate, MaxoRouteRender,
                                                       UnsafeMutableRawPointer(state), &io),
                             "Create audio callback")
        guard let io else {
            throw HALFailure(operation: "Prepare audio callback", status: kAudioHardwareUnspecifiedError)
        }
        if inputStreams.count > 1 {
            try HALFailure.check(MaxoRouteIOUseTapOnly(aggregate, io, UInt32(inputStreams.count),
                                                      UInt32(inputStreams.count - 1)),
                                 "Select playback-only input")
        }
        startAttempted = true
        try HALFailure.check(AudioDeviceStart(aggregate, io), "Start audio capture (check audio access)")
    }

    private func makePlaybackState(device: PlaybackDevice, inputBuffers: UInt32, gain: Float) throws -> OpaquePointer? {
        guard let outputs = HAL.channels(aggregate, scope: HAL.output),
              let outputStreams = HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: HAL.output),
              let mainOutput = outputStreams.first,
              let outputFormat = HAL.format(mainOutput),
              outputStreams.allSatisfy({ stream in
                  guard let format = HAL.format(stream) else { return false }
                  return Self.isFloatPCM(format) && abs(format.mSampleRate - outputFormat.mSampleRate) < 1
              }) else {
            throw HALFailure(operation: "Prepare playback stream", status: kAudioDeviceUnsupportedFormatError)
        }

        let total = outputs.reduce(0, +)
        guard total > 0 else {
            throw HALFailure(operation: "Find playback channels", status: kAudioDeviceUnsupportedFormatError)
        }
        let channels = Self.stereoChannels(on: device.object, total: total)
        return MaxoRouteIOCreate(inputBuffers, channels.left, channels.right, gain, outputFormat.mSampleRate)
    }

    private static func isFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32
            && format.mFramesPerPacket == 1
            && format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                                          ? format.mChannelsPerFrame * 4 : 4)
            && format.mSampleRate.isFinite && format.mSampleRate > 0
    }

    private static func stereoChannels(on device: AudioObjectID, total: UInt32) -> (left: UInt32, right: UInt32) {
        if total == 1 { return (0, 0) }
        var pair: (UInt32, UInt32) = (0, 0)
        var address = HAL.address(kAudioDevicePropertyPreferredChannelsForStereo, HAL.output)
        var size = UInt32(MemoryLayout.size(ofValue: pair))
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair) == noErr,
           pair.0 > 0, pair.1 > 0, pair.0 <= total, pair.1 <= total, pair.0 != pair.1 {
            return (pair.0 - 1, pair.1 - 1)
        }
        return (0, 1)
    }

    private func stop() {
        if let io {
            if startAttempted && AudioDeviceStop(aggregate, io) != noErr {
                releaseTap()
            }
            AudioDeviceDestroyIOProcID(aggregate, io)
            self.io = nil
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
        releaseTap()
        if let renderState {
            MaxoRouteIODestroy(renderState)
            self.renderState = nil
        }
    }

    private func releaseTap() {
        guard tap != 0 else { return }
        if AudioHardwareDestroyProcessTap(tap) == noErr { tap = 0 }
    }
}
