#if os(macOS)
import AppCore
import SwiftUI

/// The short prompt shown when a free-tier limit is reached: what happened, what still works, and
/// a way to Pro. Nothing the user had is taken away; it only explains why the new thing is off.
struct ProLimitSheet: View {
    let prompt: ProLimitPrompt
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(prompt.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prompt.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            HStack(spacing: 8) {
                Text("One-time purchase · no subscription")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Get Pro…") {
                    dismiss()
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(width: 440)
        .background(Theme.panel)
        .tint(Theme.accent)
    }
}

private struct ProLimitPromptModifier: ViewModifier {
    @Binding var prompt: ProLimitPrompt?
    /// Several windows watch the same prompt (the main window and Settings for breakpoints, say);
    /// only the one the user is working in shows it.
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { activeState == .inactive ? nil : prompt },
                                    set: { if $0 == nil, activeState != .inactive { prompt = nil } })) { shown in
            ProLimitSheet(prompt: shown) { prompt = nil }
        }
    }
}

extension View {
    /// Shows `prompt` as the short Pro sheet while it is set, and clears it when dismissed.
    func proLimitPrompt(_ prompt: Binding<ProLimitPrompt?>) -> some View {
        modifier(ProLimitPromptModifier(prompt: prompt))
    }
}

/// A calm note at the top of a Pro tool on the free tier: what Free includes, and a way to Pro.
struct FreeLimitBanner: View {
    let title: String
    let detail: String
    /// Off inside Settings, where the License tab is one click away.
    var showsUpgrade = true
    /// An extra button before Get Pro, such as putting a replayed message back.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "seal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ChipButtonStyle())
            }
            if showsUpgrade {
                SettingsLink { Text("Get Pro…") }
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5))
    }
}

/// On a rule that is switched on but waits for Pro, after a downgrade left more rules on than Free runs.
struct NeedsProBadge: View {
    var body: some View {
        Text("Needs Pro")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.warning.opacity(0.14), in: Capsule())
            .help("Free runs one rule of each kind at a time. This one is kept and starts working again with Pro, or when you turn the other one off.")
    }
}
#endif
