import SwiftUI
import Carbon
import ServiceManagement
import Sparkle

/// An app the rules stand down in. Kept as id + name so the list renders without
/// touching the disk for every row; a renamed or deleted app keeps working from the id.
struct ExcludedApp: Identifiable, Comparable {
    let id: String // bundle identifier
    let name: String

    static func < (a: Self, b: Self) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Sparkle normally reads `SUFeedURL` from Info.plist, but the project generates its
/// plist from build settings and Xcode only passes through the keys it knows — so the
/// feed lives here instead.
///
/// ponytail: no EdDSA key, updates are validated against the Developer ID signature
/// (Sparkle accepts either). That check happens after unarchiving; an install that needs
/// elevated privileges is validated *before* unarchiving and would need `SUPublicEDKey`
/// plus a `sign_update` step in the release workflow.
private final class UpdaterConfig: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // The dev bundle is version 1.0 (build 1), so every release looks newer to
        // Sparkle and the dev build always has an update waiting — which is what makes
        // it useful for looking at the update UI. It stops at the install: the dev build
        // is signed "Apple Development" and the release "Developer ID", so the signature
        // comparison rejects it.
        "https://github.com/dennistimmermann/momentary/releases/latest/download/appcast.xml"
    }

    /// Settings has the toggle; no need for Sparkle's permission modal.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
}

// MARK: - App state

/// Everything the app does: keep the tap running, remember the rules, and own the two
/// windows. A singleton because the app is headless — `AppDelegate` needs to reach it to
/// answer a relaunch, and there is no view around to hand it down through.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: Persisted settings
    //
    // @Published + didSet, not @AppStorage (which misbehaves inside ObservableObject).
    // Everything stored here is a native plist type, so none of it needs an encoder.

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.isEnabled)
            updateTap()
        }
    }

    /// Which modifier sends what when tapped. A missing key means "leave it alone".
    @Published var rules: [ModifierKey: TapOutput] {
        didSet {
            defaults.set(rules.reduce(into: [String: [String: Any]]()) { raw, rule in
                raw[rule.key.rawValue] = ["keyCode": Int(rule.value.keyCode),
                                          "flags": Int(rule.value.flags),
                                          "label": rule.value.label]
            }, forKey: Key.rules)
            tap.engine.rules = rules
        }
    }

    /// A release later than this after the press is a hold, not a tap. Milliseconds
    /// because that is what the slider and the label speak.
    @Published var holdThreshold: Double {
        didSet {
            defaults.set(holdThreshold, forKey: Key.holdThreshold)
            tap.engine.holdThreshold = holdThreshold / 1000
        }
    }

    /// Bundle identifier -> display name.
    @Published var excludedApps: [String: String] {
        didSet {
            defaults.set(excludedApps, forKey: Key.excludedApps)
            updateActive()
        }
    }

    @Published var showsMenuBarItem: Bool {
        didSet {
            guard showsMenuBarItem != oldValue else { return }
            defaults.set(showsMenuBarItem, forKey: Key.showsMenuBarItem)
            // Whichever way this is flipped, it is flipped from inside one of the two
            // settings surfaces — and the other one is about to become the right one.
            // Neither swap happens on its own, so both are done here, and both are
            // deferred, because the toggle that triggered them is in the surface going
            // away.
            DispatchQueue.main.async { [self] in
                if showsMenuBarItem {
                    // The panel is the settings now; the window would be a second copy.
                    settingsWindow?.close()
                } else {
                    // Removing the status item does not take its open panel with it —
                    // that is left floating with nothing to belong to.
                    dismissMenuBarPanel()
                    showSettings()
                }
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            // try? on purpose: a failed (un)register is not worth a UI error path.
            if launchAtLogin { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
            // Setting this by hand answers the offer's question, so the box goes away rather than
            // sitting there asking about a switch you just used. Safe in `init`, which assigns the
            // stored property directly and so never runs this.
            //
            // Only if it took, though. `try?` above swallows a failed `register()` — a still
            // translocated first run, or an MDM policy — and the offer is asked exactly once, so
            // latching it on a registration that silently did nothing would hide the very thing it
            // exists to prevent. The test is the same `== .enabled` that opened the offer, so the
            // two cannot disagree: any status that would not have suppressed the offer does not
            // close it either, and a `.requiresApproval` result rightly asks again next launch.
            if SMAppService.mainApp.status == .enabled { closeLaunchAtLoginOffer() }
        }
    }

    /// Sparkle persists this itself under `SUEnableAutomaticChecks`, so it needs no `Key`.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    // MARK: Live state

    /// Accessibility, checked rather than inferred, and it gates the half of the job that
    /// is easiest to miss.
    ///
    /// Momentary does two things: it *watches* modifiers, and it *posts* a key. Watching
    /// only needs Input Monitoring — which is why the tap happily reported itself running
    /// on Input Monitoring alone. Posting a synthetic key event needs Accessibility, and
    /// without it the event is created, accepted, and visible to other event taps, but
    /// never delivered to any application. Nothing anywhere reports an error.
    ///
    /// So this gates on Accessibility, which authorises both: a trusted process can
    /// create the tap *and* post. One permission, and the one that actually matters.
    @Published private(set) var hasPermission = false

    /// Which modifier sides are held right now — the settings rows light up with it, so
    /// you can find your key by pressing it instead of guessing which side macOS calls it.
    @Published private(set) var heldModifiers: Set<ModifierKey> = []

    /// True while some other app holds secure input — a password field, mostly. No event tap
    /// receives anything at all in that state, so every rule silently stops working. Nothing
    /// reports it and nothing can be done about it; the app's only honest option is to say so
    /// rather than appear healthy and do nothing.
    @Published private(set) var secureInputActive = false

    /// Whether to offer starting at login. Momentary is headless, so a user who never turns this
    /// on gets their rules silently back to nothing after a restart, with no window or Dock icon to
    /// explain why — which is a worse surprise than being asked once.
    ///
    /// Asked once and then never again, whichever way it is answered. Never asked at all if the
    /// login item is already registered, so reinstalls and upgrades stay quiet.
    @Published private(set) var offersLaunchAtLogin = false

    /// Whether the cog is open. Lives here rather than in the view so it survives the panel
    /// closing and is shared with the window — the two containers are one settings surface and
    /// should not disagree about it. Deliberately *not* persisted: a fresh launch starts closed,
    /// which is the state that shows only what you actually configured.
    @Published var settingsExpanded = false

    /// Sparkle. No EdDSA key (see UpdaterConfig), so the release build must stay
    /// signed and notarized.
    let updater: SPUStandardUpdaterController
    /// Held because `SPUStandardUpdaterController` only keeps a weak reference.
    private let updaterDelegate: UpdaterConfig

    private enum Key {
        static let isEnabled = "isEnabled"
        static let rules = "rules"
        static let holdThreshold = "holdThreshold"
        static let excludedApps = "excludedApps"
        static let showsMenuBarItem = "showsMenuBarItem"
        static let didRequestAccess = "didRequestAccess"
        static let didOfferLaunchAtLogin = "didOfferLaunchAtLogin"
    }

    /// Taken for the whole life of the process and never ended. Without it, an app showing nothing
    /// at all — menu bar item off, window closed — is a candidate for App Nap, which throttles the
    /// main run loop. That is the run loop the event tap's source and both polls are scheduled on,
    /// so key presses stop arriving and every rule quietly stops firing, with no icon left to look
    /// wrong and no window to say so. `AllowingIdleSystemSleep` because watching for a modifier is
    /// no reason to keep a Mac awake.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Watching for modifier keys held and tapped")

    private let defaults = UserDefaults.standard
    private let tap = ModifierTap()
    private var frontmostBundleID: String?
    /// Runs only while access is missing: it can be granted while we are running, and
    /// headless means there is no window reopening to notice it for us.
    private var permissionPoll: Timer?
    /// ponytail: secure input has no notification to observe, and a tap starved by it receives
    /// nothing — so there is no event to notice it *starting* from. A poll is the only way. Runs
    /// only while the tap is up, and `IsSecureEventInputEnabled()` is a single cheap call.
    private var secureInputPoll: Timer?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    /// The default: the rule this app exists to replace, on *both* ⌘ keys.
    ///
    /// Not just the left one. Telling the sides apart is the point of the app, but a
    /// left-only default is a coin flip on whichever ⌘ you actually use — and a remapped
    /// key reports as the *right* one wherever it physically sits. Turning a rule off is
    /// one click; working out why a key you have used for years quietly stopped is not.
    private static let defaultRules: [ModifierKey: TapOutput] = [
        .leftCommand: TapOutput(keyCode: 53, flags: 0, label: "⎋"),
        .rightCommand: TapOutput(keyCode: 53, flags: 0, label: "⎋"),
    ]

    private init() {
        // Sparkle's SUEnableAutomaticChecks defaults to off, and it would otherwise ask
        // for permission with a modal on the second launch. Opt in through the
        // registration domain instead: the settings toggle writes the user domain,
        // which wins from then on.
        UserDefaults.standard.register(defaults: ["SUEnableAutomaticChecks": true])
        let config = UpdaterConfig()
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: config,
                                                      userDriverDelegate: nil)
        updaterDelegate = config
        updater = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        holdThreshold = defaults.object(forKey: Key.holdThreshold) as? Double ?? 150
        excludedApps = defaults.dictionary(forKey: Key.excludedApps) as? [String: String] ?? [:]
        // Defaults on: an app with no Dock icon and nothing in the menu bar is one you
        // cannot tell is running. Turning it off is a deliberate choice, so it has to be
        // `object(forKey:)` — `bool(forKey:)` reads a missing key as false, which would
        // hand the choice back every launch.
        showsMenuBarItem = defaults.object(forKey: Key.showsMenuBarItem) as? Bool ?? true
        // Via a local, not by reading `launchAtLogin` back: touching a property with observers
        // needs `self` fully initialized, and `rules` is not set until below.
        let alreadyRegistered = SMAppService.mainApp.status == .enabled
        launchAtLogin = alreadyRegistered
        offersLaunchAtLogin = !defaults.bool(forKey: Key.didOfferLaunchAtLogin) && !alreadyRegistered

        // Nil, not empty: turning every rule off is a choice, and must not read as a
        // fresh install that gets ⌘ → ⎋ handed back on the next launch.
        if let stored = defaults.dictionary(forKey: Key.rules) as? [String: [String: Any]] {
            rules = stored.reduce(into: [:]) { rules, entry in
                guard let key = ModifierKey(rawValue: entry.key),
                      let keyCode = entry.value["keyCode"] as? Int,
                      let flags = entry.value["flags"] as? Int,
                      let label = entry.value["label"] as? String else { return }
                rules[key] = TapOutput(keyCode: UInt16(keyCode), flags: UInt64(flags), label: label)
            }
        } else {
            rules = Self.defaultRules
        }

        #if DEBUG
        TapEngine.runSelfCheck()
        #endif

        tap.engine.rules = rules
        tap.engine.holdThreshold = holdThreshold / 1000
        tap.heldChanged = { [weak self] held in
            MainActor.assumeIsolated {
                // Guarded: an equal assignment still announces a change, and this one
                // fires on every modifier press in the system.
                guard let self, self.heldModifiers != held else { return }
                self.heldModifiers = held
            }
        }
        observeFrontmostApp()
        updateActive()
        updateTap()
    }

    // MARK: - Showing the settings
    //
    // One `SettingsView`, two containers. With the menu bar item on, its panel is the
    // whole UI (see `MomentaryApp`) — no separate window, no duplicate menu. This window
    // is the other container: what you get with the item turned off, and the fallback for
    // a relaunch, since a `MenuBarExtra` panel cannot be opened programmatically.
    //
    // Plain AppKit rather than a SwiftUI `Window` scene, because those are restored at
    // login — exactly when a headless app should show nothing — and `openWindow` is
    // unreachable from the delegate that handles a relaunch.

    /// **Never opens while the menu bar item is on.** The item is the app's presence and its
    /// panel is the settings; a window alongside it is a second copy of the same thing. Every
    /// caller goes through here, so the rule holds however the request arrives — a relaunch, or
    /// the item being switched off. (Launching is not a caller: it opens nothing at all.)
    func showSettings() {
        guard !showsMenuBarItem else { return }
        show(&settingsWindow, title: "Momentary") { SettingsView(inWindow: true) }
    }

    /// SwiftUI hands out no reference to the `MenuBarExtra` panel, so it has to be found.
    /// No private class names needed: it is the visible window we did not make ourselves,
    /// floating above the normal window level the way a menu bar panel does.
    private func dismissMenuBarPanel() {
        for window in NSApp.windows
        where window !== settingsWindow && window !== aboutWindow
            && window.isVisible && window.level != .normal {
            window.orderOut(nil)
        }
    }

    func showAbout() {
        show(&aboutWindow, title: "About Momentary") { AboutView() }
    }

    private func show<Content: View>(_ window: inout NSWindow?, title: String,
                                     @ViewBuilder content: () -> Content) {
        // LSUIElement: without activating, the window opens behind everything.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Built around a hosting *controller*, not a bare NSHostingView: that is what
        // sizes the window to the SwiftUI content. Handed a contentRect instead, the
        // window keeps whatever size it was given — and .zero means an invisible window.
        let new = NSWindow(contentViewController: NSHostingController(
            rootView: content().environmentObject(self)))
        // Set after the initialiser, which hands out a resizable, miniaturizable window:
        // dropping both makes those two buttons the inert dots a panel should have.
        new.styleMask = [.titled, .closable, .fullSizeContentView]
        new.title = title
        new.titlebarAppearsTransparent = true
        new.titleVisibility = .hidden
        new.isMovableByWindowBackground = true
        // Closing a window that owns itself would deallocate it under our reference.
        new.isReleasedWhenClosed = false
        new.center()
        new.makeKeyAndOrderFront(nil)
        window = new

        // Accessibility can be granted while we run; opening a window is the cheapest
        // moment to notice, and the notice in it is what sent you to System Settings.
        retryTapIfNeeded()
    }

    // MARK: - Public API

    /// A binding that drops a write of the value already there — use this for every
    /// control, never a plain `$state.foo`.
    ///
    /// SwiftUI hands the current value back during its own update passes, and
    /// `@Published` announces a change on every assignment, equal or not. So a plain
    /// binding lets SwiftUI invalidate the very view that just wrote it, and the didSets
    /// here are not free — `isEnabled` restarts the tap, `launchAtLogin` is an XPC call.
    /// A guard in the `didSet` is too late: `objectWillChange` has already fired by then.
    ///
    /// `MenuBarExtra(isInserted:)` did this on every main-menu rebuild and spun the main
    /// thread solid, which is how this came to exist. That scene is gone now, but the
    /// hazard is SwiftUI's, not `MenuBarExtra`'s.
    func binding<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] },
                set: { if self[keyPath: keyPath] != $0 { self[keyPath: keyPath] = $0 } })
    }

    /// The offer closes in `launchAtLogin`'s `didSet`, which fires on any set — including this one.
    func acceptLaunchAtLogin() { launchAtLogin = true }

    func declineLaunchAtLogin() { closeLaunchAtLoginOffer() }

    private func closeLaunchAtLoginOffer() {
        defaults.set(true, forKey: Key.didOfferLaunchAtLogin)
        offersLaunchAtLogin = false
    }

    func setRule(_ key: ModifierKey, to output: TapOutput?) {
        rules[key] = output
    }

    func exclude(appAt url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        excludedApps[id] = FileManager.default.displayName(atPath: url.path)
    }

    func removeExclusion(_ bundleID: String) {
        excludedApps[bundleID] = nil
    }

    var sortedExclusions: [ExcludedApp] {
        excludedApps.map(ExcludedApp.init).sorted()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Without activating, Sparkle's panels open behind everything — same LSUIElement
    /// problem the windows have.
    func checkForUpdates() {
        NSApp.activate()
        updater.updater.checkForUpdates()
    }

    /// User-initiated is the only place we ask — the request is also what puts the app in
    /// the Accessibility list at all, since apps that never ask never appear there. The
    /// system shows that prompt exactly once and ignores every later request, so after
    /// the first one the list is the only way in, and the flag has to outlive the launch
    /// to know which case we are in.
    func openAccessibilitySettings() {
        if !defaults.bool(forKey: Key.didRequestAccess), !AXIsProcessTrusted() {
            defaults.set(true, forKey: Key.didRequestAccess)
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func retryTapIfNeeded() {
        if !hasPermission { updateTap() }
    }

    // MARK: - Tap lifecycle

    private func updateTap() {
        hasPermission = AXIsProcessTrusted()
        guard isEnabled, hasPermission else {
            tap.stop()
            stopSecureInputPoll()
            // Only worth watching for a grant while switching is meant to be on.
            if isEnabled { startPermissionPoll() } else { stopPermissionPoll() }
            return
        }
        stopPermissionPoll()
        tap.start()
        startSecureInputPoll()
    }

    private func startSecureInputPoll() {
        guard secureInputPoll == nil else { return }
        checkSecureInput()
        secureInputPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }
    }

    private func stopSecureInputPoll() {
        secureInputPoll?.invalidate()
        secureInputPoll = nil
        secureInputActive = false
    }

    private func checkSecureInput() {
        let active = IsSecureEventInputEnabled()
        guard active != secureInputActive else { return }
        secureInputActive = active
    }

    /// ponytail: a 2 s poll, because a TCC grant arrives with no notification worth
    /// relying on. It only runs while access is missing — a state you leave within a
    /// minute — and stops itself the moment it is granted.
    private func startPermissionPoll() {
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryTapIfNeeded() }
        }
    }

    private func stopPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    // MARK: - Exclusions

    private func observeFrontmostApp() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostBundleID = app?.bundleIdentifier
                self?.updateActive()
            }
        }
    }

    /// The tap keeps running while an excluded app is frontmost — it just stands down.
    /// Tearing it down and back up on every app switch would lose the modifier state
    /// mid-keystroke, and cost a permission check each time.
    private func updateActive() {
        tap.isActive = frontmostBundleID.map { excludedApps[$0] == nil } ?? true
    }
}

