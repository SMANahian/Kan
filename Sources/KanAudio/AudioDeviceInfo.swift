import CoreAudio
import Foundation

/// How an audio device is connected (kAudioDevicePropertyTransportType).
public enum AudioTransport: String, Sendable, Codable, Hashable {
    case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay
    case aggregate, autoAggregate, virtual, thunderbolt, pci, fireWire, avb, continuityCapture, unknown

    public init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeAutoAggregate: self = .autoAggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuityCapture
        default: self = .unknown
        }
    }
}

/// A snapshot of one Core Audio device. Plain data: safe to pass between threads.
public struct AudioDeviceInfo: Sendable, Hashable, Codable {
    /// AudioObjectID — only valid until coreaudiod restarts; persist `uid` instead.
    public var id: UInt32
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var transport: AudioTransport
    public var inputChannels: Int
    public var outputChannels: Int
    public var nominalSampleRate: Double
    /// Output data source as a four-character code: "ispk" (internal speakers), "hdpn" (headphone jack).
    public var outputDataSource: String?
    /// Terminal types of the output streams: four-character codes ("hdph" headphones, "spkr") or, for
    /// many devices, USB Audio class codes in decimal ("769" = 0x301 speaker, "770" = 0x302 headphones).
    public var outputTerminalTypes: [String]
    public var isAlive: Bool

    public init(id: UInt32 = 0, uid: String, name: String, manufacturer: String = "", transport: AudioTransport,
                inputChannels: Int = 0, outputChannels: Int = 0, nominalSampleRate: Double = 48_000,
                outputDataSource: String? = nil, outputTerminalTypes: [String] = [], isAlive: Bool = true) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.outputDataSource = outputDataSource
        self.outputTerminalTypes = outputTerminalTypes
        self.isAlive = isAlive
    }

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// Virtual drivers (ZoomAudioDevice, BlackHole, Teams, Krisp) and aggregates.
    public var isVirtualOrAggregate: Bool {
        transport == .virtual || transport == .aggregate || transport == .autoAggregate
    }

    /// A physical microphone Kan can record from.
    public var isRealInput: Bool { hasInput && isAlive && !isVirtualOrAggregate }

    // MARK: Reading from the HAL (not real-time safe)

    public static func read(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = HAL.deviceUID(id) else { return nil }
        let outputScope = kAudioObjectPropertyScopeOutput
        var dataSource: String?
        if HAL.hasProperty(id, kAudioDevicePropertyDataSource, scope: outputScope),
           let src = try? HAL.readUInt32(id, kAudioDevicePropertyDataSource, scope: outputScope) {
            dataSource = HAL.code(src)
        }
        let terminals = HAL.streams(of: id, input: false).compactMap { stream -> String? in
            guard let t = try? HAL.readUInt32(stream, kAudioStreamPropertyTerminalType), t != 0 else { return nil }
            return HAL.code(t)
        }
        return AudioDeviceInfo(
            id: id, uid: uid, name: HAL.name(id),
            manufacturer: (try? HAL.readString(id, kAudioObjectPropertyManufacturer)) ?? "",
            transport: AudioTransport(code: (try? HAL.readUInt32(id, kAudioDevicePropertyTransportType)) ?? 0),
            inputChannels: HAL.channelCount(of: id, input: true),
            outputChannels: HAL.channelCount(of: id, input: false),
            nominalSampleRate: (try? HAL.readFloat64(id, kAudioDevicePropertyNominalSampleRate)) ?? 0,
            outputDataSource: dataSource, outputTerminalTypes: terminals,
            isAlive: HAL.hasProperty(id, kAudioDevicePropertyDeviceIsAlive)
                ? HAL.readBool(id, kAudioDevicePropertyDeviceIsAlive) : true)
    }

    public static func all() -> [AudioDeviceInfo] { HAL.allDevices().compactMap(read) }

    public static func device(uid: String) -> AudioDeviceInfo? { HAL.device(forUID: uid).flatMap(read) }

    public static func defaultInput() -> AudioDeviceInfo? { HAL.defaultInputDevice().flatMap(read) }

    public static func defaultOutput() -> AudioDeviceInfo? { HAL.defaultOutputDevice().flatMap(read) }
}

/// Where a device plays sound, for the echo (mic bleed) risk.
public enum OutputRoute: String, Sendable, Codable {
    case builtInSpeakers, headphones, bluetoothHeadphones, bluetoothSpeaker, usbHeadset, usbSpeaker
    case hdmi, displayPort, airPlay, virtual, other

    /// Sound is audible in the room, so the microphone hears the other side too.
    public var isLoudspeaker: Bool {
        switch self {
        case .builtInSpeakers, .bluetoothSpeaker, .usbSpeaker, .hdmi, .displayPort, .airPlay: return true
        case .headphones, .bluetoothHeadphones, .usbHeadset, .virtual, .other: return false
        }
    }
}

/// Heuristic loudspeaker-vs-headphones classification from transport type, data source, terminal
/// type and (as a last resort) the device name. Pure: works on `AudioDeviceInfo` values.
public enum LoudspeakerClassifier {
    private static let speakerWords = ["speaker", "soundlink", "soundcore", "boom", "flip", "charge", "pill",
                                       "homepod", "sonos", "speak ", "display audio"]
    private static let headphoneWords = ["headphone", "airpods", "headset", "earbud", "earphone", "buds"]

    // USB Audio class terminal types (IOAudioTypes.h), as Core Audio reports them for many devices.
    private static let headphoneTerminals: Set<String> = [
        "hdph",
        "770",      // 0x0302 headphones
        "771",      // 0x0303 head-mounted display audio
        "1025",     // 0x0401 handset
        "1026",     // 0x0402 headset
    ]
    private static let speakerTerminals: Set<String> = [
        "spkr", "lfes",
        "769",      // 0x0301 speaker
        "772",      // 0x0304 desktop speaker
        "773",      // 0x0305 room speaker
        "774",      // 0x0306 communication speaker
        "1027",     // 0x0403 speakerphone
        "1028",     // 0x0404 echo-suppressing speakerphone
        "1029",     // 0x0405 echo-cancelling speakerphone
    ]

    public static func route(of device: AudioDeviceInfo) -> OutputRoute {
        let name = device.name.lowercased() + " "
        let headphoneTerminal = device.outputTerminalTypes.contains { headphoneTerminals.contains($0) }
        let speakerTerminal = !headphoneTerminal && device.outputTerminalTypes.contains { speakerTerminals.contains($0) }
        let soundsLikeSpeaker = speakerWords.contains { name.contains($0) }
        let soundsLikeHeadphones = headphoneWords.contains { name.contains($0) }
        switch device.transport {
        case .builtIn:
            if let source = device.outputDataSource {
                if source == "hdpn" { return .headphones }
                if source == "ispk" { return .builtInSpeakers }
            }
            // Apple silicon Macs publish "External Headphones" as its own built-in device.
            if headphoneTerminal || soundsLikeHeadphones { return .headphones }
            return .builtInSpeakers
        case .hdmi:
            return .hdmi
        case .displayPort:
            return .displayPort
        case .airPlay:
            return .airPlay
        case .bluetooth, .bluetoothLE:
            if headphoneTerminal || soundsLikeHeadphones { return .bluetoothHeadphones }
            if soundsLikeSpeaker { return .bluetoothSpeaker }
            // Most Bluetooth audio devices used for calls are worn (AirPods, headsets); speakers
            // usually say so in their name, and their terminal type is not trusted over the name.
            return .bluetoothHeadphones
        case .usb:
            if headphoneTerminal { return .usbHeadset }
            if speakerTerminal || (soundsLikeSpeaker && !soundsLikeHeadphones) { return .usbSpeaker }
            return .usbHeadset
        case .virtual, .aggregate, .autoAggregate:
            return .virtual
        case .thunderbolt, .pci, .fireWire, .avb, .continuityCapture, .unknown:
            return .other
        }
    }

    public static func isLoudspeaker(_ device: AudioDeviceInfo) -> Bool { route(of: device).isLoudspeaker }

    /// True if any real output device the call app uses (or, when none is known, the default
    /// output) plays out loud. Virtual devices are skipped: they forward to a real device.
    public static func isLoudspeakerSuspected(outputUIDs: [String], devices: [AudioDeviceInfo],
                                              defaultOutputUID: String?) -> Bool {
        func real(_ uids: [String]) -> [AudioDeviceInfo] {
            uids.compactMap { uid in devices.first { $0.uid == uid } }.filter { route(of: $0) != .virtual }
        }
        var candidates = real(outputUIDs)
        if candidates.isEmpty, let d = defaultOutputUID { candidates = real([d]) }
        return candidates.contains { isLoudspeaker($0) }
    }
}

/// Which microphone to record "me" from.
public enum MicrophoneSelector {
    public struct Choice: Sendable, Equatable {
        public var uid: String
        /// True when recording from the system default input (follow it when it changes).
        public var followsDefault: Bool

        public init(uid: String, followsDefault: Bool) {
            self.uid = uid
            self.followsDefault = followsDefault
        }
    }

    /// The first preferred UID (the devices the call app records from) that is a physical input;
    /// otherwise the default input (even a virtual one — e.g. a noise-cancelling driver the user
    /// chose); otherwise any physical input.
    public static func choose(preferredUIDs: [String], devices: [AudioDeviceInfo], defaultInputUID: String?) -> Choice? {
        if let uid = firstPhysicalInput(among: preferredUIDs, devices: devices) { return Choice(uid: uid, followsDefault: false) }
        if let uid = defaultInputUID, let d = devices.first(where: { $0.uid == uid }), d.hasInput, d.isAlive {
            return Choice(uid: uid, followsDefault: true)
        }
        if let d = devices.first(where: { $0.isRealInput }) { return Choice(uid: d.uid, followsDefault: true) }
        return nil
    }

    /// The first of `uids` that is a physical microphone (skips virtual drivers like ZoomAudioDevice,
    /// dead devices and the speakers' echo-reference "inputs" of voice-processing clients).
    public static func firstPhysicalInput(among uids: [String], devices: [AudioDeviceInfo]) -> String? {
        uids.first { uid in devices.first(where: { $0.uid == uid })?.isRealInput == true }
    }
}
