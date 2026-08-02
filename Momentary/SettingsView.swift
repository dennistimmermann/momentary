import SwiftUI
import UniformTypeIdentifiers

/// The settings. Stock SwiftUI controls and system semantic colours throughout, so the panel
/// inherits the popover material and dark mode without being asked.
///
/// The organising idea: **only the rules you have set are on screen.** Eight fixed rows were a
/// repetitive wall of which six stayed empty forever, so the cog reveals the rest — the same
/// arrangement Keychange uses for its hidden devices.
///
/// Pressing an unassigned modifier while the list is short brings its row back on its own, which
/// matters more than it sounds: a key remapped in System Settings reports as the *right-hand* side
/// wherever it physically sits (see `ModifierKey`), so pressing it is the only reliable way to find
/// out which row is yours. That reveal lasts until the panel is opened again or the cog is touched
/// — a row must not vanish underneath the field you are still using.
@MainActor
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    /// True in the standalone window. The window has room, it is not something you flick open for
    /// a glance, and there is no small surface to protect — so it shows everything and drops the
    /// cog. Collapsing only earns its place in the menu bar panel.
    var inWindow = false

    @State private var choosingApp = false
    @State private var recording: ModifierKey?

    /// Modifiers pressed while the list was short. Cleared on the next open and whenever the cog is
    /// touched, never in between.
    @State private var revealed: Set<ModifierKey> = []
    /// Hold ⌥ while opening to see every row, the way the system's own menu bar applets reveal
    /// their extras. Sampled once per open, and it leaves the cog alone.
    @State private var optionHeld = false
    @State private var cogHovered = false

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if state.secureInputActive {
                infoBox("Paused — another app has secure input on, so no key press reaches Momentary. It resumes on its own when that app lets go.",
                        symbol: "lock")
            }
            // Both containers. Nothing lives in only one of them: the menu bar item is on by
            // default, so a window-only offer would never be seen on a default install.
            if state.offersLaunchAtLogin {
                infoBox("Momentary is running. Allow it to automatically launch after a restart?",
                        symbol: "power", tint: .blue,
                        actions: [("Launch at login", state.acceptLaunchAtLogin),
                                  ("Not now", state.declineLaunchAtLogin)])
            }

            if state.hasPermission {
                rulesSection
                if inWindow || state.settingsExpanded { settingsSection }
            } else {
                permissionSection
            }
        }
        .padding(6)
        .padding(.bottom, 6)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: state.heldModifiers) { _, held in reveal(held) }
        .onAppear(perform: sampleOpenState)
        // onAppear alone misses reopens when SwiftUI keeps the view alive, so also re-sample
        // whenever the panel becomes the key window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sampleOpenState()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Momentary").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66) // 0.06em at 11pt
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !inWindow { cogButton }
            masterSwitch
        }
        .padding(.top, 4)
        .padding(.horizontal, 9)
        .padding(.bottom, 6)
    }

    /// Bare glyph, left of the master switch — the same affordance Keychange uses.
    private var cogButton: some View {
        Button {
            state.settingsExpanded.toggle()
            // Touching the cog re-decides what is on screen, so a reveal from earlier is spent.
            revealed = []
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: cogHovered ? .labelColor : .secondaryLabelColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { cogHovered = $0 }
        .accessibilityLabel(state.settingsExpanded ? "Hide settings" : "Show settings")
    }

    /// Inert without permission: nothing it could switch on would work.
    private var masterSwitch: some View {
        Toggle("Enable Momentary", isOn: state.binding(\.isEnabled))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!state.hasPermission)
    }

    /// What the panel decides once per open: nothing is revealed until you press something.
    private func sampleOpenState() {
        optionHeld = NSEvent.modifierFlags.contains(.option)
        revealed = []
        state.retryTapIfNeeded()
    }

    /// Pressing an unassigned modifier puts its row back, and leaves it there.
    private func reveal(_ held: Set<ModifierKey>) {
        guard !inWindow, !state.settingsExpanded else { return }
        for key in held where state.rules[key] == nil { revealed.insert(key) }
    }

    // MARK: - Rules

    /// Fixed modifier order — ⌃ ⌥ ⇧ ⌘, left before right — never the order rules were set in, or
    /// rows would jump as you configure them. `allCases` is already declared in that order.
    private var visibleModifiers: [ModifierKey] {
        guard !inWindow, !state.settingsExpanded, !optionHeld else { return ModifierKey.allCases }
        return ModifierKey.allCases.filter { state.rules[$0] != nil || revealed.contains($0) }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(visibleModifiers) { ruleRow($0) }
            hintLine
        }
        .padding(.top, 2)
    }

    private func ruleRow(_ key: ModifierKey) -> some View {
        let held = state.heldModifiers.contains(key)
        return settingsRow(key.title, highlighted: held, accented: held) {
            HStack(spacing: 6) {
                ComboField(
                    output: Binding(get: { state.rules[key] }, set: { state.setRule(key, to: $0) }),
                    isRecording: Binding(get: { recording == key },
                                         set: { recording = $0 ? key : nil }),
                    focused: held
                )

                Button { state.setRule(key, to: nil) } label: {
                    Image(systemName: "delete.left").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .disabled(state.rules[key] == nil)
                .opacity(state.rules[key] == nil ? 0 : 1)
                .accessibilityLabel("Clear \(key.title)")
            }
        }
    }

    /// One line that always says the most useful thing available: what a recording field wants,
    /// what you are holding, or how to find your key.
    @ViewBuilder
    private var hintLine: some View {
        let held = ModifierKey.allCases.first { state.heldModifiers.contains($0) }
        Group {
            if recording != nil {
                Text("⎋ to cancel · ⌫ to clear").foregroundStyle(.secondary)
            } else if let held, let rule = state.rules[held] {
                Text("Holding \(held.title) — release within \(Int(state.holdThreshold)) ms to send \(rule.display)")
                    .foregroundStyle(Color.accentColor)
            } else if let held {
                Text("Holding \(held.title) — no rule set yet")
                    .foregroundStyle(Color.accentColor)
            } else if visibleModifiers.count < ModifierKey.allCases.count {
                Text("Hold any modifier to bring its row back.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.top, 2)
    }

    // MARK: - Settings, behind the cog

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            separator
            thresholdRow
            separator
            exclusions
            separator

            settingsToggle("Show menu bar item", isOn: state.binding(\.showsMenuBarItem),
                           hint: "Turn this off and Momentary runs with nothing on screen at all. Launching it again always brings this window back, so it stays reachable either way.")
            settingsToggle("Launch at login", isOn: state.binding(\.launchAtLogin))
            settingsToggle("Check for updates automatically",
                           isOn: state.binding(\.automaticallyChecksForUpdates))

            separator

            settingsButton("About", action: state.showAbout)
            settingsButton("Quit", action: state.quit)
        }
    }

    private var thresholdRow: some View {
        settingsRow("Hold threshold",
                    hint: "How long you can hold the modifier and still have it count as a tap. Longer is more forgiving but delays nothing — the modifier itself always works immediately.") {
            HStack(spacing: 8) {
                Slider(value: state.binding(\.holdThreshold), in: 80...500, step: 10)
                    .controlSize(.small)
                    .frame(width: 130)
                Text("\(Int(state.holdThreshold)) ms")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var exclusions: some View {
        ForEach(state.sortedExclusions) { app in
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button { state.removeExclusion(app.id) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                .accessibilityLabel("Stop excluding \(app.name)")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
        }

        settingsButton("Exclude App…") { choosingApp = true }
            .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
                if case .success(let url) = result { state.exclude(appAt: url) }
            }
    }

    /// Replaces the rules. The header stays, so the panel still looks like itself and the cog is
    /// still there.
    private var permissionSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text("Momentary needs Accessibility access")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            Text("It sends the key a tapped modifier is mapped to, and macOS will not deliver a synthetic key press from an app without this access. Until then, no rule does anything.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Accessibility Settings…", action: state.openAccessibilitySettings)
                .buttonStyle(.link)
                .font(.system(size: 12.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.horizontal, 40)
        .padding(.bottom, 34)
    }

    // MARK: - Shared furniture

    /// The one notice shape in the app: a symbol, a sentence, and any number of choices as links
    /// beneath it. No tint is the grey wash for a state that heals itself; a tint means the app is
    /// waiting on you, and spends the only colour on the panel.
    ///
    /// The actions sit on their own line rather than running on as the last words of the sentence,
    /// because that is the only shape that also works for two of them — and one slightly plainer
    /// box beats two that look almost alike.
    private func infoBox(_ text: String, symbol: String, tint: Color? = nil,
                         actions: [(String, () -> Void)] = []) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                // Nudged onto the first line's cap height; the symbol's own box sits high.
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            if index > 0 { Text("·").foregroundStyle(.tertiary) }
                            Button(action.0, action: action.1)
                                .buttonStyle(.link)
                                // Explicit: a tinted box sets the text to .primary so it reads on
                                // the tint, and that would swallow the link style's own colour.
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(tint == nil ? .secondary : .primary)
        .padding(8)
        .background(tint.map { AnyShapeStyle($0.opacity(0.22)) } ?? AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 3)
        .padding(.bottom, 6)
    }

    private var separator: some View {
        Divider().padding(.vertical, 7).padding(.horizontal, 9)
    }

    /// Title (plus ⓘ when there's a `hint`), a spacer, and the trailing control. The row itself is
    /// inert — the control is the control.
    private func settingsRow(_ title: String, hint: String? = nil, highlighted: Bool = false,
                             accented: Bool = false,
                             @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: accented ? .semibold : .regular))
                    .foregroundStyle(accented ? Color.accentColor : Color(nsColor: .labelColor))
                if hint != nil {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        // Applied after the padding, so it changes no layout and an unhighlighted row is
        // pixel-identical to what it was.
        .background(highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                                : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .help(hint ?? "")
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, hint: String? = nil) -> some View {
        settingsRow(title, hint: hint) {
            Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 13))
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
    }
}

// MARK: - Formatting an output

extension TapOutput {
    /// "⌘⎋" — modifier glyphs in the order every macOS menu prints them, then the key.
    var display: String {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        let glyphs: [(NSEvent.ModifierFlags, String)] =
            [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + label
    }
}

// MARK: - Recording a key combination

/// Click, then press the combination you want sent. While armed it eats key presses with a local
/// monitor, so recording ⌘Q records ⌘Q instead of quitting.
private struct ComboField: View {
    @Binding var output: TapOutput?
    @Binding var isRecording: Bool
    /// True while this row's modifier is physically held — the field takes a focus ring so the
    /// row's highlight reads as one thing.
    var focused = false

    @State private var monitor: Any?

    var body: some View {
        Button { isRecording.toggle() } label: {
            Text(isRecording ? "Press a key…" : (output?.display ?? "—"))
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
                .frame(width: 108, height: 22)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(ringColor, lineWidth: isRecording || focused ? 2 : 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, on in on ? arm() : disarm() }
        .onDisappear(perform: disarm)
    }

    private var labelStyle: AnyShapeStyle {
        if isRecording { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(Color(nsColor: output == nil ? .tertiaryLabelColor : .labelColor))
    }

    private var ringColor: Color {
        isRecording || focused ? .accentColor : Color(nsColor: .separatorColor)
    }

    private func arm() {
        // Returning nil swallows the event: the combination being recorded must not also fire
        // while it is being recorded.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
            switch event.keyCode {
            case 53 where bare: break            // ⎋ cancels, leaving the rule as it was
            case 51 where bare: output = nil     // ⌫ clears
            default: output = Self.capture(event)
            }
            isRecording = false
            return nil
        }
    }

    private func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func capture(_ event: NSEvent) -> TapOutput {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        return TapOutput(keyCode: event.keyCode, flags: UInt64(flags.rawValue), label: name(of: event))
    }

    /// Captured at record time, while the event still knows what it types. Only keys with no
    /// printable character need the table.
    private static func name(of event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        guard let character = event.charactersIgnoringModifiers?.uppercased(),
              let scalar = character.unicodeScalars.first, scalar.value >= 0x20
        else { return "Key \(event.keyCode)" }
        return character
    }

    private static let specialKeys: [UInt16: String] = [
        53: "⎋", 48: "⇥", 49: "␣", 36: "↩", 76: "⌤", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]
}
