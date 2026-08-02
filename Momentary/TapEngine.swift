import CoreGraphics
import Foundation

// MARK: - Models

/// One physical modifier key, sides told apart.
///
/// `CGEventFlags` only says "a command key is down", never which one — but macOS also
/// reports the side in the low, device-dependent bits of the same field, and those are
/// what make a rule for left ⌘ possible without touching right ⌘.
/// Masks: `IOKit/hidsystem/IOLLEvent.h`.
enum ModifierKey: String, CaseIterable, Identifiable {
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    var id: String { rawValue }

    var deviceMask: UInt64 {
        switch self {
        case .leftControl:  0x0000_0001
        case .leftShift:    0x0000_0002
        case .rightShift:   0x0000_0004
        case .leftCommand:  0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption:   0x0000_0020
        case .rightOption:  0x0000_0040
        case .rightControl: 0x0000_2000
        }
    }

    /// "Left ⌘". Side first, because the rows are read as a column of sides.
    var title: String {
        switch self {
        case .leftControl:  "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftOption:   "Left ⌥"
        case .rightOption:  "Right ⌥"
        case .leftShift:    "Left ⇧"
        case .rightShift:   "Right ⇧"
        case .leftCommand:  "Left ⌘"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Which sides an event reports as held.
    static func sides(in flags: CGEventFlags) -> Set<ModifierKey> {
        Set(allCases.filter { flags.rawValue & $0.deviceMask != 0 })
    }
}

/// The key combination a tapped modifier sends.
///
/// `label` is captured when the combination is recorded rather than derived from the key
/// code later — the recorder already has the event, which knows the glyph, so nothing
/// here needs a key-code-to-name table beyond the handful of keys that have no glyph.
struct TapOutput: Equatable {
    var keyCode: UInt16
    /// `CGEventFlags` raw value: the modifiers to send alongside the key.
    var flags: UInt64
    var label: String
}

/// What the tap saw. The engine never touches a `CGEvent`, which is what keeps its
/// decisions testable without an event stream.
enum TapInput: Equatable {
    /// A `flagsChanged`: every modifier side currently held.
    case modifiers(down: Set<ModifierKey>)
    /// Anything that means the modifier is being *used* rather than tapped — a key
    /// press, a mouse button, a scroll.
    case otherInput
}

// MARK: - Engine

/// Decides whether a modifier was tapped or held.
///
/// No timer. The only moment the answer is ever needed is the release, so comparing two
/// timestamps there settles it with nothing to schedule, cancel, or leak.
struct TapEngine {
    /// Which modifier sends what when tapped. A missing key means "leave it alone".
    var rules: [ModifierKey: TapOutput]
    /// A release later than this after the press is a hold, not a tap.
    var holdThreshold: TimeInterval

    /// Every side currently held, as of the last event.
    private var down: Set<ModifierKey> = []
    /// The one modifier that could still turn out to be a tap: pressed alone, with
    /// nothing since. nil as soon as anything disqualifies it.
    private var candidate: (key: ModifierKey, pressedAt: TimeInterval)?

    /// Spelled out because the synthesised memberwise initialiser is private —
    /// `down` and `candidate` are.
    init(rules: [ModifierKey: TapOutput] = [:], holdThreshold: TimeInterval = 0.15) {
        self.rules = rules
        self.holdThreshold = holdThreshold
    }

    /// Forgets what is held. Called whenever the tap stops seeing events — while another
    /// app is excluded, or between a stop and a start — because a stale `down` set would
    /// make the next diff report presses and releases that never happened.
    mutating func reset() {
        down = []
        candidate = nil
    }

    /// Returns the combination to send, or nil for "nothing to do", which is almost always.
    mutating func handle(_ input: TapInput, at time: TimeInterval) -> TapOutput? {
        switch input {
        case .otherInput:
            // A modifier used with anything is a modifier — and "anything" has to include
            // the mouse. Disarming on key presses alone means ⌘-clicking a link, or
            // ⌘-scrolling to zoom, still fires the rule when you let go.
            candidate = nil
            return nil

        case .modifiers(let now):
            let pressed = now.subtracting(down)
            let released = down.subtracting(now)
            down = now

            var output: TapOutput?

            // A release is the only thing that can fire, and only for the candidate:
            // releasing the second of two held modifiers has no claim on a tap.
            if let candidate, released.contains(candidate.key) {
                if time - candidate.pressedAt < holdThreshold {
                    output = rules[candidate.key]
                }
                self.candidate = nil
            }

            // Any press ends the running candidate's chance — including a second modifier
            // going down on top of it. A press only becomes the new candidate when it is
            // alone, which is what "tapped in isolation" means.
            if !pressed.isEmpty {
                candidate = nil
                if let key = pressed.first, pressed.count == 1, down.count == 1, rules[key] != nil {
                    candidate = (key, time)
                }
            }

            return output
        }
    }
}

// MARK: - Self-check

#if DEBUG
extension TapEngine {

    /// The whole decision table in one runnable check, called from `AppState.init()` in
    /// debug builds — so a broken rule crashes the dev build instead of quietly
    /// misfiring in a way you would only notice as the occasional stray Escape.
    static func runSelfCheck() {
        let esc = TapOutput(keyCode: 53, flags: 0, label: "⎋")
        func fresh() -> TapEngine { TapEngine(rules: [.leftCommand: esc], holdThreshold: 0.15) }

        // Tap: pressed alone, released inside the threshold.
        var tap = fresh()
        assert(tap.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(tap.handle(.modifiers(down: []), at: 0.05) == esc)

        // Hold: same press, released after the threshold.
        var hold = fresh()
        assert(hold.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(hold.handle(.modifiers(down: []), at: 1.0) == nil)

        // Used as a modifier: ⌘C.
        var shortcut = fresh()
        assert(shortcut.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(shortcut.handle(.otherInput, at: 0.02) == nil)
        assert(shortcut.handle(.modifiers(down: []), at: 0.05) == nil)

        // ⌘-click and ⌘-scroll: the same path, and the two most easily forgotten.
        var click = fresh()
        assert(click.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(click.handle(.otherInput, at: 0.02) == nil)
        assert(click.handle(.modifiers(down: []), at: 0.05) == nil)

        // No rule for right ⌘: tapping it does nothing.
        var otherSide = fresh()
        assert(otherSide.handle(.modifiers(down: [.rightCommand]), at: 0) == nil)
        assert(otherSide.handle(.modifiers(down: []), at: 0.05) == nil)

        // Both ⌘s down, release one, then the other: neither was pressed alone.
        var both = fresh()
        assert(both.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(both.handle(.modifiers(down: [.leftCommand, .rightCommand]), at: 0.02) == nil)
        assert(both.handle(.modifiers(down: [.leftCommand]), at: 0.04) == nil)
        assert(both.handle(.modifiers(down: []), at: 0.06) == nil)

        // A dropped event (excluded app, tap restart) must not leave a phantom press
        // behind: after reset the next snapshot is the truth, not a diff against it.
        var stale = fresh()
        assert(stale.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        stale.reset()
        assert(stale.handle(.modifiers(down: []), at: 0.05) == nil)

        // Two taps in a row: the first must not consume the second.
        var twice = fresh()
        assert(twice.handle(.modifiers(down: [.leftCommand]), at: 0) == nil)
        assert(twice.handle(.modifiers(down: []), at: 0.05) == esc)
        assert(twice.handle(.modifiers(down: [.leftCommand]), at: 0.3) == nil)
        assert(twice.handle(.modifiers(down: []), at: 0.35) == esc)
    }
}
#endif
