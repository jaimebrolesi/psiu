import CoreAudio
import Foundation
import os

/// Psiu puts the headset on after 3 s of sound and takes it off after 3 s of silence: an alert (under 2 s)
/// never puts it on, and the pause between two songs or two audio messages doesn't take it off.
public struct Listening: Sendable {
    public static let delay = 3.0
    public private(set) var on = false
    private var changingSince: Double?

    public init() {}

    /// Called with what plays now; returns whether the headset is on.
    public mutating func update(playing: Bool, now: Double) -> Bool {
        if playing == on { changingSince = nil; return on }
        let since = changingSince ?? now
        changingSince = since
        if now - since >= Self.delay { on = playing; changingSince = nil }
        return on
    }
}

/// Whether another app is sending sound to an output (music, a call, a video, an audio message), from Core Audio's
/// process objects (macOS 14.2). Asks no permission and never hears the sound: Core Audio calls back when an app
/// starts or stops playing, and nothing runs in between, except a check every 15 s while the headset is on.
public final class AudioOutput: @unchecked Sendable {
    /// Processes that only play alerts.
    static let ignored: Set<String> = ["systemsoundserverd"]
    /// Core Audio announces kAudioProcessPropertyIsRunning (input or output) but, on macOS 26, never
    /// kAudioProcessPropertyIsRunningOutput: both are watched, and the output one is read.
    static let announced = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]
    /// While something plays, checked again this often, in case an app stops its output but keeps its microphone.
    static let recheck = 15.0

    private let queue = DispatchQueue(label: "io.github.jaimebrolesi.psiu.audio")
    private let state = OSAllocatedUnfairLock(initialState: false)
    // Touched only on `queue`.
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var counts: [AudioObjectID: Bool] = [:]   // whether a process's sound counts (not Psiu, not an alert)
    private var recheckPending = false

    public init() {}

    /// True while an app other than Psiu plays sound.
    public var playing: Bool { state.withLock { $0 } }

    public func start() {
        guard #available(macOS 14.2, *) else { return }
        queue.async { [self] in
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue) { [weak self] _, _ in
                self?.refresh()
            }
            refresh()
        }
    }

    /// Watches the processes that appeared, forgets those that left, and checks who is playing.
    @available(macOS 14.2, *)
    private func refresh() {
        let processes = Set(Self.processes())
        for (id, block) in watched where !processes.contains(id) {
            for selector in Self.announced {
                var running = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(id, &running, queue, block)
            }
            watched[id] = nil
            counts[id] = nil
        }
        for id in processes where watched[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
            for selector in Self.announced {
                var running = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(id, &running, queue, block)
            }
            watched[id] = block
            counts[id] = Self.pid(id) != getpid() && !Self.ignored.contains(Self.bundleID(id) ?? "")
        }
        check()
    }

    @available(macOS 14.2, *)
    private func check() {
        let now = watched.keys.contains { counts[$0] == true && Self.runsOutput($0) }
        state.withLock { $0 = now }
        if now && !recheckPending {
            recheckPending = true
            queue.asyncAfter(deadline: .now() + Self.recheck) { [weak self] in
                self?.recheckPending = false
                self?.check()
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    @available(macOS 14.2, *)
    private static func processes() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    @available(macOS 14.2, *)
    private static func runsOutput(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr && value != 0
    }

    @available(macOS 14.2, *)
    private static func pid(_ id: AudioObjectID) -> pid_t {
        var a = address(kAudioProcessPropertyPID)
        var value: pid_t = 0, size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : 0
    }

    @available(macOS 14.2, *)
    private static func bundleID(_ id: AudioObjectID) -> String? {
        var a = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
