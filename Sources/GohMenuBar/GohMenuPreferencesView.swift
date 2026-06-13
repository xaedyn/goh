import SwiftUI

/// The Settings window. Binds the injected `GohMenuPreferences` + `GohMenuLoginItem`
/// (never touches UserDefaults / SMAppService directly — unit-test-safe).
///
/// Only **General** settings are backed today (launch-at-login, completion
/// notifications, the icon-progress pref), so the window is a single native
/// grouped `Form` — no tab bar (one pane needs none). The window title
/// ("goh Settings") + traffic lights come from the hosting `Window` scene.
public struct GohMenuPreferencesView: View {
    private let preferences: any GohMenuPreferences
    private let loginItem: any GohMenuLoginItem

    @Environment(\.dismiss) private var dismiss

    @State private var notificationsEnabled: Bool
    @State private var showProgressOnIcon: Bool
    @State private var launchAtLoginEnabled: Bool
    @State private var loginItemStatus: GohLoginItemStatus
    @State private var loginItemError: String?

    public init(
        preferences: any GohMenuPreferences,
        loginItem: any GohMenuLoginItem
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        _notificationsEnabled = State(initialValue: preferences.notificationsEnabled)
        _showProgressOnIcon = State(initialValue: preferences.showProgressOnIcon)
        _launchAtLoginEnabled = State(
            initialValue: loginItem.status() == .enabled || loginItem.status() == .requiresApproval)
        _loginItemStatus = State(initialValue: loginItem.status())
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                        .tint(GohTheme.accent)
                        .disabled(loginItemStatus == .unsupported)
                        .onChange(of: launchAtLoginEnabled) { _, newValue in applyLoginItemToggle(newValue) }
                        .accessibilityLabel("Launch at login")
                    if loginItemStatus == .unsupported {
                        caption("Not available in this build.", color: .secondary)
                    }
                    if loginItemStatus == .requiresApproval {
                        caption("Enabled — approve in System Settings → General → Login Items.", color: .secondary)
                    }
                    if let loginItemError {
                        caption(loginItemError, color: GohTheme.error)
                    }
                }

                Section {
                    Toggle(isOn: $showProgressOnIcon) {
                        Text("Show progress on the icon")
                        Text("Brighten the arrow as a download completes")
                    }
                    .tint(GohTheme.accent)
                    .onChange(of: showProgressOnIcon) { _, newValue in preferences.showProgressOnIcon = newValue }
                    .accessibilityLabel("Show download progress on the menu-bar icon")

                    Toggle("Notify when downloads finish", isOn: $notificationsEnabled)
                        .tint(GohTheme.accent)
                        .onChange(of: notificationsEnabled) { _, newValue in preferences.notificationsEnabled = newValue }
                        .accessibilityLabel("Enable completion notifications")
                }
            }
            .formStyle(.grouped)

            Divider()

            Text(buildLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(8)
        }
        .frame(width: 440, height: 360)
        .onAppear {
            // Refresh status when the window opens (user may have approved in Settings).
            loginItemStatus = loginItem.status()
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buildLine: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "goh \(version) · macOS \(os) · Apple Silicon"
    }

    // MARK: Login-item handling (preserved)

    private func applyLoginItemToggle(_ enable: Bool) {
        loginItemError = nil
        do {
            if enable {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            preferences.launchAtLoginEnabled = enable
            loginItemStatus = loginItem.status()
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } catch GohLoginItemError.registrationFailed(let message) {
            loginItemError = "Could not update login item: \(message)"
            let status = loginItem.status()
            preferences.launchAtLoginEnabled = status == .enabled || status == .requiresApproval
            launchAtLoginEnabled = preferences.launchAtLoginEnabled
        } catch GohLoginItemError.unsupported {
            loginItemError = "Launch at login is not available when running as a bare binary."
            launchAtLoginEnabled = false
        } catch {
            loginItemError = "Unexpected error: \(error.localizedDescription)"
        }
    }
}
