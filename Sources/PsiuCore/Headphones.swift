import CoreAudio
import Foundation
import os

/// What Core Audio says about the Mac's default output, enough to tell headphones from speakers.
public struct OutputRoute: Sendable, Equatable {
    public var transport: UInt32          // kAudioDevicePropertyTransportType
    public var dataSource: UInt32?        // the built-in output's source: 'ispk' (speakers) or 'hdpn' (headphone jack)
    public var terminals: [UInt32]        // kAudioStreamPropertyTerminalType of each output stream

    public init(transport: UInt32, dataSource: UInt32? = nil, terminals: [UInt32] = []) {
        self.transport = transport
        self.dataSource = dataSource
        self.terminals = terminals
    }

    /// Core Audio reports terminals both as its own codes and as the USB ones (0x0301 speaker, 0x0302 headphones,
    /// 0x0402 headset).
    static let headphoneTerminals: Set<UInt32> = [kAudioStreamTerminalTypeHeadphones, 0x0302, 0x0402]
    static let speakerTerminals: Set<UInt32> = [kAudioStreamTerminalTypeSpeaker, 0x0301]

    /// Wired headphones in the jack, a USB headset, or a Bluetooth device that doesn't call itself a speaker.
    public var headphones: Bool {
        if dataSource == fourCC("hdpn") { return true }
        if terminals.contains(where: Self.headphoneTerminals.contains) { return true }
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return bluetooth && !terminals.contains(where: Self.speakerTerminals.contains)
    }
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

/// Whether the Mac's sound goes to headphones, from the default output device. Asks no permission and never hears
/// the sound: Core Audio calls back when the default output changes or headphones go in or out of the jack.
public final class Headphones: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.jaimebrolesi.psiu.audio")
    private let state = OSAllocatedUnfairLock(initialState: false)
    // Touched only on `queue`.
    private var device: AudioObjectID = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?

    public init() {}

    /// True while the default output is headphones.
    public var on: Bool { state.withLock { $0 } }

    public func start() {
        queue.async { [self] in
            var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue) { [weak self] _, _ in
                self?.follow()
            }
            follow()
        }
    }

    /// Watches the current default output (its jack and its streams) and checks it.
    private func follow() {
        let now = Self.defaultOutput()
        if now != device {
            if let block = deviceListener {
                for var a in Self.deviceAddresses { AudioObjectRemovePropertyListenerBlock(device, &a, queue, block) }
            }
            device = now
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
            for var a in Self.deviceAddresses { AudioObjectAddPropertyListenerBlock(device, &a, queue, block) }
            deviceListener = block
        }
        check()
    }

    private func check() {
        let headphones = Self.route(device).headphones
        state.withLock { $0 = headphones }
    }

    private static let deviceAddresses = [kAudioDevicePropertyDataSource, kAudioDevicePropertyStreams].map {
        address($0, kAudioObjectPropertyScopeOutput)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID {
        uint32(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice)) ?? 0
    }

    static func route(_ device: AudioObjectID) -> OutputRoute {
        OutputRoute(transport: uint32(device, address(kAudioDevicePropertyTransportType)) ?? 0,
                    dataSource: uint32(device, address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)),
                    terminals: streams(device).compactMap { uint32($0, address(kAudioStreamPropertyTerminalType)) })
    }

    private static func streams(_ device: AudioObjectID) -> [AudioObjectID] {
        var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard device != 0, AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var a = address, value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard id != 0, AudioObjectHasProperty(id, &a) else { return nil }
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }
}
