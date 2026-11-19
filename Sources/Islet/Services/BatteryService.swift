import Foundation
import IOKit.ps

/// Real-time battery and power-adapter state, pushed by IOKit power sources.
@MainActor
final class BatteryService {
    /// Called on the main thread, only when the state actually changed after `start()`.
    var onChange: ((BatteryState) -> Void)?
    /// `BatteryState.unknown` until `start()` has run.
    private(set) var state: BatteryState = .unknown

    /// Created by the first `start()`, then reused until deinit (see `Registration`).
    private var registration: Registration?
    private var isListening = false

    init() {}

    deinit {
        // The teardown has to run on the main thread, where the callback fires,
        // so the context can never be freed under a callback in flight.
        guard let registration else { return }
        if Thread.isMainThread {
            registration.invalidate()
        } else {
            DispatchQueue.main.async { registration.invalidate() }
        }
    }

    /// Reads the current state synchronously (without calling `onChange`), then
    /// listens for changes. Does nothing when already started.
    func start() {
        guard !isListening else { return }

        // Register before reading: a change landing in between stays queued on
        // the notification port instead of being lost.
        let registration = self.registration ?? Registration(service: self)
        self.registration = registration

        if let current = Self.readState() { state = current }

        // No registration means IOKit refused; the next start() tries again.
        guard let registration else { return }
        // Common modes: keep updating while a menu or a drag tracks the run loop.
        CFRunLoopAddSource(CFRunLoopGetMain(), registration.source, .commonModes)
        isListening = true
    }

    func stop() {
        guard isListening, let registration else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes)
        isListening = false
    }

    fileprivate func refresh() {
        // The notification also fires for time-remaining estimates, which do
        // not change anything we publish.
        guard isListening, let current = Self.readState(), current != state else { return }
        state = current
        onChange?(current)
    }

    // MARK: - Reading

    /// `nil` when the power sources could not be read: the caller keeps its last
    /// known state rather than flashing "no battery" on a transient failure.
    private static func readState() -> BatteryState? {
        // "Copy" functions hand over a +1 reference; the description below is a
        // "Get" and stays owned by the snapshot.
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                      .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  // An empty battery bay is still listed, flagged as not present.
                  description[kIOPSIsPresentKey] as? Bool != false
            else { continue }

            // A battery whose level cannot be read is a glitch, not a desktop
            // Mac: treat it as a failed read instead of hiding the battery.
            guard let percent = percent(from: description) else { return nil }

            return BatteryState(
                hasBattery: true,
                percent: percent,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }

        // Desktop Mac (a UPS, if any, is not an internal battery): always on AC.
        return BatteryState(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)
    }

    /// Apple batteries publish both capacities in percent, but the keys may
    /// also carry mAh, hence the ratio.
    private static func percent(from description: [String: Any]) -> Int? {
        guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              maximum > 0
        else { return nil }

        let ratio = (current / maximum * 100).rounded()
        // Int(_:) traps on NaN and infinity.
        guard ratio.isFinite else { return nil }
        return Int(min(max(ratio, 0), 100))
    }
}

// MARK: - Run loop plumbing

/// What the C callback receives. The back-reference is weak so that a
/// notification can never reach a deallocated service.
private final class CallbackContext {
    weak var service: BatteryService?

    init(service: BatteryService) {
        self.service = service
    }
}

/// The IOKit notification source and the +1 held on its callback context.
///
/// One per service, only added to / removed from the run loop by start() and
/// stop(): IOKit never gives back the notify port behind a source, however it
/// is torn down, so creating one per start() would leak a Mach port each time.
///
/// Unchecked Sendable because it is never shared: the only hop it makes is the
/// one-way hand-off to the main thread when the service dies off the main thread.
private struct Registration: @unchecked Sendable {
    let source: CFRunLoopSource
    let context: Unmanaged<CallbackContext>

    init?(service: BatteryService) {
        // IOKit only keeps the raw pointer, so this +1 is what keeps the
        // context alive until `invalidate()` gives it back.
        let context = Unmanaged.passRetained(CallbackContext(service: service))
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourcesDidChange, context.toOpaque())?
            .takeRetainedValue()
        else {
            context.release()
            return nil
        }
        self.source = source
        self.context = context
    }

    /// Main thread only. Invalidating takes the source off the run loop and
    /// guarantees it never fires again, which makes releasing the context safe.
    func invalidate() {
        CFRunLoopSourceInvalidate(source)
        context.release()
    }
}

/// Runs on the main run loop, the only one the source is ever added to.
private func powerSourcesDidChange(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    MainActor.assumeIsolated {
        context.service?.refresh()
    }
}
