import CoreAudio
import Foundation

struct HALFailure: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String { "\(operation) (Core Audio \(status))" }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw HALFailure(operation: operation, status: status) }
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let global = kAudioObjectPropertyScopeGlobal
    static let output = kAudioDevicePropertyScopeOutput
    static let input = kAudioDevicePropertyScopeInput

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = global) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = global, initial: T) -> T? {
        var property = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = global) -> [AudioObjectID]? {
        var property = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr else {
            return nil
        }
        if size == 0 { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(ids.prefix(Int(size) / stride)) : nil
    }

    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32]? {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr else {
            return nil
        }
        if size == 0 { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else {
            return nil
        }
        let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    static func format(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }
}

struct PlaybackDevice: Identifiable, Equatable {
    let object: AudioObjectID
    let id: String
    let name: String
    let transport: UInt32
    let rate: Double
    let inputStreams: [AudioObjectID]
    let outputStreams: [AudioObjectID]

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "wave.3.right"
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: "airplay.audio"
        default: "speaker.wave.2"
        }
    }

    static func available() -> (devices: [PlaybackDevice], defaultID: AudioObjectID) {
        let ids = HAL.ids(HAL.system, kAudioHardwarePropertyDevices) ?? []
        let devices: [PlaybackDevice] = ids.compactMap { object in
            guard let uid = HAL.string(object, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.maxo.route."),
                  HAL.read(object, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1,
                  let outputs = HAL.ids(object, kAudioDevicePropertyStreams, scope: HAL.output),
                  !outputs.isEmpty else { return nil }
            return PlaybackDevice(
                object: object,
                id: uid,
                name: HAL.string(object, kAudioObjectPropertyName) ?? uid,
                transport: HAL.read(object, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0,
                rate: HAL.read(object, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0,
                inputStreams: HAL.ids(object, kAudioDevicePropertyStreams, scope: HAL.input) ?? [],
                outputStreams: outputs
            )
        }
        let defaultID = HAL.read(HAL.system, kAudioHardwarePropertyDefaultOutputDevice,
                                 initial: AudioObjectID(0)) ?? 0
        return (devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, defaultID)
    }
}
