import SwiftUI

@main
struct MomentaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        // The menu bar item's panel *is* the settings — same `SettingsView` the window
        // shows, no separate menu.
        //
        // `.window` style, and `MenuBarExtra` rather than a hand-built `NSStatusItem` +
        // `NSPopover`, because this is the only thing that draws the borderless panel a
        // menu bar app should have. An `NSPopover` always draws an arrow pointing at the
        // status item; there is no API to remove it.
        //
        // `isInserted` must go through `AppState.binding` — SwiftUI writes it back on
        // every main-menu rebuild, and a plain `$state.foo` binding spins the main thread
        // solid. That was a real hang, not a theoretical one.
        MenuBarExtra(isInserted: state.binding(\.showsMenuBarItem)) {
            SettingsView().environmentObject(state)
        } label: {
            // Dimmed whenever no rule can fire — switched off, or secure input is swallowing
            // every event. Both look the same from the menu bar; the panel says which.
            Image(nsImage: MenuBarMark.image(dimmed: !state.isEnabled || state.secureInputActive))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item mark: the same two bars as the app icon, one short and one tall — one key drawn
/// twice, held for different lengths.
///
/// Its own geometry, not the app icon's. With no plate framing them the bars need to be taller and
/// start higher to hold the same weight, which is why the numbers here don't match `AppIcon`'s.
/// Drawn rather than shipped as an asset: two rounded rects scale exactly, and a template image
/// needs no light/dark variants — AppKit inverts it and applies its own opacity.
enum MenuBarMark {
    /// The mark at 40% ink when the app is not acting — switched off, or starved of events by
    /// secure input. Same treatment Keychange uses for its disabled state: the shape is still
    /// yours to recognise, it is simply not doing anything. A template image keeps its alpha, so
    /// AppKit dims rather than redraws it.
    static func image(dimmed: Bool) -> NSImage { dimmed ? faded : full }

    private static let full = make(alpha: 1)
    private static let faded = make(alpha: 0.4)

    private static func make(alpha: CGFloat) -> NSImage {
        // Handoff geometry in a 100×100 space; both bars are centred on y=50.
        let short = NSRect(x: 27, y: 30, width: 17, height: 40)
        let tall = NSRect(x: 56, y: 12, width: 17, height: 76)
        let radius: CGFloat = 8.5

        let side: CGFloat = 16
        let k = side / 100
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.withAlphaComponent(alpha).setFill()
            for bar in [short, tall] {
                let r = NSRect(x: bar.minX * k, y: bar.minY * k,
                               width: bar.width * k, height: bar.height * k)
                NSBezierPath(roundedRect: r, xRadius: radius * k, yRadius: radius * k).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touching the singleton is what starts the tap and installs the status item,
        // whether or not anything is ever shown. That is the whole of launching.
        //
        // Nothing is opened here. A first run always has the menu bar item on — it defaults on,
        // and a first run is exactly when nobody has turned it off — so `showSettings` could only
        // ever hit its own guard and do nothing. The status item is the app's arrival.
        _ = AppState.shared
    }

    /// Launching Momentary while it is already running is the way back in. Launch
    /// Services turns that second launch into this, rather than a second process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppState.shared.showSettings()
        return true
    }

    /// Closing the settings is not quitting: the whole app is what happens while nothing
    /// is on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
