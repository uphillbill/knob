import AudioToolbox
import CoreAudio
import Foundation

/// Thin helpers over the Core Audio HAL C API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let hasHardwareVolume: Bool
    }

    struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    // MARK: - Property access

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default fallback: T) -> T {
        var addr = addr
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Channel count of each buffer in a device's stream configuration for one direction.
    static func bufferChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Virtual (client-side) format of every stream of a device in one direction.
    /// This is the format the IO proc sees.
    static func streamFormats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioStreamBasicDescription] {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return [] }
        return streams.map { get($0, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription()) }
    }

    static func isFloat32(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM
            && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && f.mBitsPerChannel == 32
    }

    static func describe(_ f: AudioStreamBasicDescription) -> String {
        let float = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return "\(f.mChannelsPerFrame)ch \(Int(f.mSampleRate))Hz \(f.mBitsPerChannel)bit \(float ? "float" : "int")\(nonInterleaved ? " non-interleaved" : "")"
    }

    // MARK: - Devices

    static func device(forUID uid: String) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr ? device : unknown
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        get(device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, address(kAudioHardwarePropertyDefaultOutputDevice), default: unknown)
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    static func outputDevices() -> [Device] {
        objectIDs(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard bufferChannels(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +) > 0 else { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("Knob-") else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return Device(id: id, uid: uid, name: name, hasHardwareVolume: hasHardwareVolume(id))
        }
    }

    // MARK: - Hardware ("virtual main") volume, for devices that support it

    private static var mainVolumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    static func hasHardwareVolume(_ device: AudioObjectID) -> Bool {
        var addr = mainVolumeAddress
        guard AudioHardwareServiceHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static func hardwareVolume(_ device: AudioObjectID) -> Float {
        var addr = mainVolumeAddress
        var volume: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr else { return 1 }
        return volume
    }

    static func setHardwareVolume(_ device: AudioObjectID, _ value: Float) {
        var addr = mainVolumeAddress
        var volume = Float32(max(0, min(1, value)))
        AudioHardwareServiceSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }

    // MARK: - Processes (macOS 14.2+)

    static func audioProcesses() -> [AudioProcess] {
        objectIDs(system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            let pid: pid_t = get(obj, address(kAudioProcessPropertyPID), default: -1)
            guard pid > 0 else { return nil }
            let bundleID = string(obj, kAudioProcessPropertyBundleID) ?? ""
            let running: UInt32 = get(obj, address(kAudioProcessPropertyIsRunningOutput), default: 0)
            return AudioProcess(objectID: obj, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object)
        return status == noErr ? object : unknown
    }
}

struct HALError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw HALError(what: what, status: status) }
}
