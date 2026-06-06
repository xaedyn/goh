import SwiftUI

/// Preferences sheet: two toggles — notifications and launch-at-login.
/// Injected with GohMenuPreferences and GohMenuLoginItem so the view never
/// touches UserDefaults or SMAppService directly (unit-test-safe contract).
public struct GohMenuPreferencesView: View {
    private let preferences: any GohMenuPreferences
    private let loginItem: any GohMenuLoginItem

    @State private var notificationsEnabled: Bool
    @State private var launchAtLoginEnabled: Bool
    @State private var loginItemStatus: GohLoginItemStatus
    @State private var loginItemError: String? = nil

    public init(
        preferences: any GohMenuPreferences,
        loginItem: any GohMenuLoginItem
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        _notificationsEnabled = State(initialValue: preferences.notificationsEnabled)
        _launchAtLoginEnabled = State(
            initialValue: loginItem.status() == .enabled || loginItem.status() == .requiresApproval)
        _loginItemStatus = State(initialValue: loginItem.status())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences")
                .font(.headline)

            Toggle("Enable completion notifications", isOn: $notificationsEnabled)
                .accessibilityLabel("Enable completion notifications")
                .onChange(of: notificationsEnabled) { _, newValue in
                    preferences.notificationsEnabled = newValue
                }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    loginItemStatus == .unsupported
                        ? "Launch at login (not available in debug mode)"
                        : "Launch at login",
                    isOn: $launchAtLoginEnabled)
                .disabled(loginItemStatus == .unsupported)
                .accessibilityLabel(
                    loginItemStatus == .unsupported
                        ? "Launch at login, not available when running as a bare binary"
                        : "Launch at login")
                .onChange(of: launchAtLoginEnabled) { _, newValue in
                    applyLoginItemToggle(newValue)
                }

                if loginItemStatus == .requiresApproval {
                    Text("Enabled — approve in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Launch at login is enabled but awaiting approval in System Settings, General, Login Items.")
                }

                if let error = loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 200)
        .onAppear {
            // Refresh status when the sheet opens (user may have approved in Settings).
            loginItemStatus = loginItem.status()
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        }
    }

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
            // Reflect the actual post-operation status.
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } catch GohLoginItemError.registrationFailed(let message) {
            loginItemError = "Could not update login item: \(message)"
            preferences.launchAtLoginEnabled = loginItem.status() == .enabled
            launchAtLoginEnabled = preferences.launchAtLoginEnabled
        } catch GohLoginItemError.unsupported {
            loginItemError = "Launch at login is not available when running as a bare binary."
            launchAtLoginEnabled = false
        } catch {
            loginItemError = "Unexpected error: \(error.localizedDescription)"
        }
    }
}
