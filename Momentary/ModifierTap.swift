import CoreGraphics
import Foundation

/// The `CGEventTap` that feeds `TapEngine` and posts what it decides.
///
/// Listen-only on purpose: the callback's return value is ignored, so this build cannot
/// alter or withhold anything you type — it watches, and it injects. It also means a
/// callback that overruns can only get the tap disabled, never stall the input stream.
///
/// That is a commitment, not a guarantee, and the difference matters the moment anyone
/// writes it up as one. `.listenOnly` is an argument on one call, and the app holds
/// Accessibility — it has to, to post the output — which is exactly the grant an active
/// tap wants. Changing it would need no new permission and raise no prompt. The claims the
/// code does earn are narrower: key codes are never read for anything that is not a
/// modifier, and nothing is stored or sent.
///
/// `start()` returning true is not evidence of permission. Without it macOS hands back a
/// valid port that simply never receives anything, which is why `AppState` gates on
/// `AXIsProcessTrusted()` instead of trusting this.
final class ModifierTap {

    var engine = TapEngine()

    /// Read before every event. False while the frontmost app is excluded — a plain
    /// stored flag rather than a callback, so the hot path is one bool.
    var isActive = true {
        didSet { if !isActive { engine.reset() } }
    }

    /// Which modifier sides are held, whenever that changes. Purely for the settings
    /// rows: "left" and "right" are what macOS reports, not where the key is, so the only
    /// honest way to find your key is to press it and see which row answers.
    var heldChanged: ((Set<ModifierKey>) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Marks the events we post so they don't come back around as input.
    private static let injectedMarker: Int64 = 0x4442_4C54_414B // "DBLTAK"

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<ModifierTap>.fromOpaque(context).takeUnretainedValue()
            tap.handle(type: type, event: event)
            // Listen-only: the return value is ignored, and the event is never ours to change.
            return Unmanaged.passUnretained(event)
        }

        // Mouse buttons and the scroll wheel are in here because they are what tells a
        // ⌘-click apart from a ⌘ tap. Without them, letting go after ⌘-clicking a link
        // sends an Escape.
        let mask = [CGEventType.flagsChanged, .keyDown,
                    .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        engine.reset()
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    // MARK: - The hot path

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap whose callback ran too long; just switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            engine.reset()
            return
        }
        // Reported before the guards below: the settings rows show which key you are
        // actually pressing, and that has to stay true even where the rules stand down.
        var sides: Set<ModifierKey>?
        if type == .flagsChanged {
            let held = ModifierKey.sides(in: event.flags)
            sides = held
            heldChanged?(held)
        }

        guard isActive,
              event.getIntegerValueField(.eventSourceUserData) != Self.injectedMarker
        else { return }

        let input: TapInput = sides.map { .modifiers(down: $0) } ?? .otherInput

        let t = Self.seconds(event.timestamp)
        #if DEBUG
        // Unit check, because getting this wrong is silent: the engine is handed seconds
        // and trusts them, so a wrong scale makes every tap look like a long hold and
        // nothing ever fires. Its own self-check cannot see this — it is pure, and never
        // touches an event clock.
        assert(abs(t - ProcessInfo.processInfo.systemUptime) < 2,
               "CGEvent.timestamp is not being converted to seconds since boot")
        #endif
        guard let output = engine.handle(input, at: t) else { return }
        send(output)
    }

    /// The event's own timestamp, not the clock as the callback runs: the tap is on the
    /// main run loop, and a busy main thread would otherwise stretch a tap into a hold.
    ///
    /// `CGEvent.timestamp` is nanoseconds since boot, already — despite being typed as a
    /// mach absolute time. Putting it through `mach_timebase_info` scales it by another
    /// 125/3 on Apple silicon, which made a 60 ms tap measure as 2.5 s and every rule
    /// silently dead. Hence the assertion at the call site.
    private static func seconds(_ timestamp: UInt64) -> TimeInterval {
        TimeInterval(timestamp) / 1_000_000_000
    }

    // MARK: - Injecting the output

    /// Posted on the next run loop turn rather than from inside the callback, so it lands
    /// *after* the modifier release we are reacting to. Posted from here it can overtake
    /// that release, and the key arrives still carrying the modifier — a tap of ⌘ then
    /// sends ⌘⎋ instead of ⎋.
    private func send(_ output: TapOutput) {
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: output.keyCode, keyDown: isDown)
                else { continue }
                // Assigned, not OR'd: the source carries the live hardware modifiers, and
                // the point is to send exactly the recorded combination and nothing else.
                event.flags = CGEventFlags(rawValue: output.flags)
                event.setIntegerValueField(.eventSourceUserData, value: Self.injectedMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }
}
