import CoreAudio
import Foundation

/// Real-time output volume and default output device, straight from the
/// CoreAudio HAL: no polling, and no permission prompt.
@MainActor
final class AudioService {
    /// Main thread. Only for changes that happen after `start()`.
    var onVolumeChange: ((VolumeState) -> Void)?
    /// Main thread. Only when the default output device changes after `start()`,
    /// never for the device found at start.
    var onOutputChange: ((AudioOutput) -> Void)?

    /// `nil` when the device has no volume control (HDMI, some DACs).
    private(set) var volume: VolumeState?
    private(set) var output: AudioOutput?

    private var isRunning = false
    /// The device the volume listeners are attached to.
    private var deviceID = kAudioObjectUnknown
    /// The last real device seen since `start()`. It outlives a moment without
    /// any device (coreaudiod restarting), so that the same device coming back
    /// is not announced as a switch.
    private var lastDevice: DeviceIdentity?
    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var pendingDeviceCheck: DispatchWorkItem?
    private var isVolumeRefreshQueued = false

    init() {}

    /// Idempotent. Reads the current device and volume without any callback.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Listen before reading: a switch landing in between is then picked up
        // by the listener instead of being lost.
        let system = AudioObjectID(kAudioObjectSystemObject)
        // After a coreaudiod restart the object IDs we hold may name other
        // objects, hence the second selector.
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted] {
            let listener = PropertyListener(objectID: system, address: HAL.address(selector)) { [weak self] in
                self?.scheduleDeviceCheck()
            }
            if let listener { systemListeners.append(listener) }
        }

        attach(to: HAL.defaultOutputDevice())
        refreshVolume(notify: false)
        output = HAL.output(for: deviceID)
    }

    /// `volume` and `output` keep their last value so the island can still show them.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingDeviceCheck?.cancel()
        pendingDeviceCheck = nil
        systemListeners.forEach { $0.remove() }
        systemListeners.removeAll()
        detach()
        // Whatever the next `start()` finds is its initial device, never a switch.
        lastDevice = nil
    }

    // MARK: - Default device

    /// Bluetooth devices announce themselves two or three times in a row: wait
    /// for the HAL to settle so a single `onOutputChange` goes out.
    private func scheduleDeviceCheck() {
        guard isRunning else { return }
        pendingDeviceCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkDefaultDevice() }
        }
        pendingDeviceCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.deviceDebounce, execute: check)
    }

    private func checkDefaultDevice() {
        pendingDeviceCheck = nil
        guard isRunning else { return }

        let previous = lastDevice
        // Re-attach even when the ID is unchanged: listeners belong to an object
        // ID, and after a coreaudiod restart that ID may name another object.
        attach(to: HAL.defaultOutputDevice())

        // State first, callbacks last: a handler may well call `stop()`.
        output = HAL.output(for: deviceID)
        if let previous, let lastDevice, !lastDevice.isSameDevice(as: previous) {
            // The new device's level is not a change the user made: stay silent.
            refreshVolume(notify: false)
            if let output { onOutputChange?(output) }
        } else {
            // Not a switch: a re-announcement, no device at all for now, or the
            // first device since `start()`. The volume may still have moved
            // while the listeners were being swapped.
            refreshVolume(notify: true)
        }
    }

    private func attach(to device: AudioObjectID) {
        detach()
        deviceID = device
        guard device != kAudioObjectUnknown else { return }
        lastDevice = DeviceIdentity(id: device, uid: HAL.string(device, kAudioDevicePropertyDeviceUID))
        // Every candidate is registered, even the ones the device lacks today:
        // the HAL accepts them, and a control that shows up late is then heard.
        for address in HAL.volumeAddresses {
            let listener = PropertyListener(objectID: device, address: address) { [weak self] in
                self?.volumeListenerFired()
            }
            if let listener { deviceListeners.append(listener) }
        }
    }

    private func detach() {
        deviceListeners.forEach { $0.remove() }
        deviceListeners.removeAll()
        deviceID = kAudioObjectUnknown
    }

    // MARK: - Volume

    /// One key press fires several listeners (four on built-in speakers) and a
    /// read costs two round trips to coreaudiod: read once per burst, after it,
    /// instead of once per listener.
    private func volumeListenerFired() {
        guard isRunning, !isVolumeRefreshQueued else { return }
        isVolumeRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isVolumeRefreshQueued = false
                // The service may have been stopped or moved to another device
                // meanwhile, and a block queued just before its listener was
                // removed can still arrive. No device ID travels with either:
                // the read looks at the current device, so the worst a late one
                // can do is find nothing new.
                guard self.isRunning else { return }
                self.refreshVolume(notify: true)
            }
        }
    }

    private func refreshVolume(notify: Bool) {
        let fresh = HAL.outputVolume(of: deviceID)
        // A control appearing or vanishing is not a volume change either.
        guard notify, let previous = volume, let fresh else {
            volume = fresh
            return
        }
        // Several reads can still follow one key press: only a real change goes
        // out. `volume` is left alone otherwise, so a slow drift still adds up
        // to a change.
        let levelMoved = abs(fresh.level - previous.level) > Tuning.levelEpsilon
        guard levelMoved || fresh.isMuted != previous.isMuted else { return }
        volume = fresh
        onVolumeChange?(fresh)
    }

    // MARK: - Symbol

    /// The SF Symbol that best describes an output device. The name wins over the
    /// transport type: AirPods and Beats are Bluetooth too, and the built-in
    /// headphone jack reports the same transport as the speakers.
    nonisolated static func symbolName(forDeviceNamed name: String, transportType: UInt32) -> String {
        // Fold case, accents and no-break spaces: the match must not depend on
        // how the owner or the system language spelled the name.
        let key = name
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        if key.contains("airpods max") { return "airpodsmax" }
        if key.contains("airpods pro") { return "airpodspro" }
        if key.contains("airpods") { return "airpods" }
        if key.contains("beats") { return "beats.headphones" }
        if ["headphone", "casque", "ecouteur"].contains(where: key.contains) { return "headphones" }

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "hifispeaker.fill"
        }
    }
}

private enum Tuning {
    /// A volume key step is 1/16 (1/64 with ⌥⇧): far above this, while the
    /// float noise between two reads of the same level stays far below.
    static let levelEpsilon: Float = 0.001
    static let deviceDebounce: TimeInterval = 0.25
}

/// What tells two devices apart. Unlike the object ID, the UID survives the HAL
/// re-creating a device (Bluetooth reconnecting, coreaudiod restarting).
private struct DeviceIdentity {
    var id: AudioObjectID
    var uid: String?

    func isSameDevice(as other: DeviceIdentity) -> Bool {
        if let uid, let otherUID = other.uid { return uid == otherUID }
        return id == other.id
    }
}

// MARK: - Listener

/// A listener as a real Objective-C block object. The HAL removes a listener by
/// block identity, but the SDK types it as a Swift closure, and Swift wraps a
/// closure in a brand-new block each time it crosses into C: removal would then
/// report success and leave the listener registered for good.
private typealias ListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// The C signature of the add and remove calls as Swift imports it…
private typealias ImportedListenerCall = @convention(c) (
    AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?, @escaping AudioObjectPropertyListenerBlock
) -> OSStatus
/// …and the very same C signature, taking the block object untouched.
private typealias ListenerCall = @convention(c) (
    AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?, ListenerBlock
) -> OSStatus

private let addListenerBlock = unsafeBitCast(
    AudioObjectAddPropertyListenerBlock as ImportedListenerCall, to: ListenerCall.self
)
private let removeListenerBlock = unsafeBitCast(
    AudioObjectRemovePropertyListenerBlock as ImportedListenerCall, to: ListenerCall.self
)

/// One HAL listener registration: the block lives here, with the address it was
/// registered for, until it is handed back to the HAL for removal.
private final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: ListenerBlock
    private var isRegistered = false

    init?(objectID: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.objectID = objectID
        self.address = address
        // Registered on DispatchQueue.main below, so this already runs on the main thread.
        self.block = { _, _ in MainActor.assumeIsolated(handler) }
        guard addListenerBlock(objectID, &self.address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        isRegistered = true
    }

    func remove() {
        guard isRegistered else { return }
        isRegistered = false
        // Fails harmlessly when the device is already gone.
        _ = removeListenerBlock(objectID, &address, DispatchQueue.main, block)
    }

    // Safety net for a service released without `stop()`.
    deinit { remove() }
}

// MARK: - HAL access

private enum HAL {
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc'): the level
    /// the volume keys and the menu bar slider act on. Spelled out because its
    /// constant only lives in a deprecated AudioToolbox header.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    /// Everything `outputVolume(of:)` may read, so any of them changing triggers a new read.
    static let volumeAddresses: [AudioObjectPropertyAddress] = [
        outputAddress(virtualMainVolume),
        outputAddress(kAudioDevicePropertyVolumeScalar),
        outputAddress(kAudioDevicePropertyVolumeScalar, channel: 1),
        outputAddress(kAudioDevicePropertyVolumeScalar, channel: 2),
        outputAddress(kAudioDevicePropertyMute),
        outputAddress(kAudioDevicePropertyMute, channel: 1),
        outputAddress(kAudioDevicePropertyMute, channel: 2),
    ]

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        channel: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: channel)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        number(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice))
            ?? kAudioObjectUnknown
    }

    static func output(for device: AudioObjectID) -> AudioOutput? {
        guard device != kAudioObjectUnknown else { return nil }
        let name = string(device, kAudioObjectPropertyName) ?? ""
        let transport: UInt32 = number(device, address(kAudioDevicePropertyTransportType))
            ?? kAudioDeviceTransportTypeUnknown
        return AudioOutput(
            name: name,
            symbolName: AudioService.symbolName(forDeviceNamed: name, transportType: transport)
        )
    }

    static func outputVolume(of device: AudioObjectID) -> VolumeState? {
        guard device != kAudioObjectUnknown, let level = outputLevel(of: device), level.isFinite else { return nil }
        return VolumeState(level: min(max(level, 0), 1), isMuted: isOutputMuted(device))
    }

    private static func outputLevel(of device: AudioObjectID) -> Float? {
        if let level: Float32 = number(device, outputAddress(virtualMainVolume)) { return level }
        if let level: Float32 = number(device, outputAddress(kAudioDevicePropertyVolumeScalar)) { return level }
        // No main control: the device only exposes one fader per channel.
        let channels: [Float32] = [1, 2].compactMap {
            number(device, outputAddress(kAudioDevicePropertyVolumeScalar, channel: $0))
        }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    private static func isOutputMuted(_ device: AudioObjectID) -> Bool {
        if let muted: UInt32 = number(device, outputAddress(kAudioDevicePropertyMute)) { return muted != 0 }
        let channels: [UInt32] = [1, 2].compactMap {
            number(device, outputAddress(kAudioDevicePropertyMute, channel: $0))
        }
        return !channels.isEmpty && channels.allSatisfy { $0 != 0 }
    }

    /// Reads a fixed-size numeric property. `nil` when the object lacks it: the
    /// HAL then answers with an error, at once and without touching `value`.
    static func number<T: Numeric>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        var value: T = 0
        let expectedSize = UInt32(MemoryLayout<T>.size)
        var size = expectedSize
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, size == expectedSize else { return nil }
        return value
    }

    /// Reads a CFString property of the global scope.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = HAL.address(selector)
        // The HAL hands the string over at +1: Unmanaged gives that single
        // reference to ARC, which releases it exactly once.
        var reference: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let reference else { return nil }
        return reference.takeRetainedValue() as? String
    }
}
