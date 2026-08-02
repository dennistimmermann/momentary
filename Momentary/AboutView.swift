import SwiftUI

/// The About panel: mark, name, slogan, version metadata, link rows, footer. Same shape
/// as Keychange's, minus its `WindowChrome` — `AppState.show` sets the chrome, because
/// here the window is an `NSWindow` we own rather than a SwiftUI scene.
struct AboutView: View {

    // Edit these three in place; nothing else hardcodes them.
    private let slogan = "Tap a modifier, send a key. Hold it, and it's just a modifier."
    private let repoURL = URL(string: "https://github.com/dennistimmermann/momentary")!
    private let coffeeURL = URL(string: "https://ko-fi.com/tmrmn")!

    private let sparkleURL = "https://github.com/sparkle-project/Sparkle"

    @EnvironmentObject private var state: AppState
    /// Keyed by row label — not every row is a link, so a URL won't do as the key.
    @State private var hoveredRow: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .padding(.top, 40)

            Text("Momentary")
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.675) // -0.025em
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.top, 22)

            Text(slogan)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.horizontal, 36)

            metaRow
                .padding(.top, 14)

            tip
                .padding(.top, 14)

            Divider()
                .padding(.top, 22)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                // Next to the version it acts on; the "check automatically" setting stays
                // with the other settings.
                actionRow("Check for Updates…", action: state.checkForUpdates)
                linkRow("GitHub repository", detail: repoURL.host.map { $0 + repoURL.path } ?? "", url: repoURL)
                linkRow("Momentary is free — buy me a coffee", detail: "", url: coffeeURL)
            }
            .padding(.top, 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 420, height: 548) // +66 for the tip box, -18 for the dropped footer line
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// `Version 1.0 · Build 1 · MIT`, read from the bundle.
    private var metaRow: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return HStack(spacing: 7) {
            ForEach(Array(["Version \(version)", "Build \(build)", "MIT"].enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").opacity(0.5)
                }
                Text(item)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    /// Whole row is the hit target; the ↗ is a glyph, not a button.
    private func linkRow(_ label: String, detail: String, url: URL) -> some View {
        actionRow(label, detail: detail) {
            NSWorkspace.shared.open(url)
        }
        .accessibilityLabel("\(label), opens \(url.host ?? url.absoluteString)")
    }

    private func actionRow(_ label: String, detail: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(hoveredRow == label ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hoveredRow = $0 ? label : nil }
        }
        .buttonStyle(.plain)
    }

    /// Nothing else points at the ⌥ reveal — the cog shows every row too, but only ⌥ does it
    /// without changing what the panel looks like next time.
    private var tip: some View {
        Text("Hold ⌥ while opening Momentary to show every modifier, including the ones you have not assigned.")
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .labelColor))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            // Same box as the panel's secure-input notice.
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Text("Updates by [Sparkle](\(sparkleURL)), MIT licensed.")
            Text("© 2026 Dennis Timmermann")
        }
        .font(.system(size: 11))
        .lineSpacing(6.6) // 1.6 line-height at 11pt
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
    }
}
