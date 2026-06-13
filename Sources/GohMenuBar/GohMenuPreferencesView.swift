import SwiftUI

/// The Settings window. Binds the injected `GohMenuPreferences` + `GohMenuLoginItem`
/// (never touches UserDefaults / SMAppService directly — unit-test-safe).
///
/// Only the **General** tab has real, backed settings today (launch-at-login,
/// completion notifications, and the icon-progress pref). The redesign's
/// Downloads / Trust / Advanced tabs would each require new persisted state +
/// engine behavior, so they are intentionally not shown (an empty tab reads as
/// unfinished). The window title ("goh Settings") + traffic lights come from the
/// hosting `Window` scene.
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
        VStack(spacing: 14) {
            tabBar
            generalCard
            footer
        }
        .padding(16)
        .frame(width: 380)
        .containerBackground(.thinMaterial, for: .window)
        .onAppear {
            // Refresh status when the window opens (user may have approved in Settings).
            loginItemStatus = loginItem.status()
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        }
    }

    // MARK: Tab bar

    /// Only the real tab is shown. More tabs appear if/when backed settings exist.
    private var tabBar: some View {
        HStack(spacing: 22) {
            tabItem("General", systemImage: "gearshape", active: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func tabItem(_ title: String, systemImage: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 16))
            Text(title).font(GohTheme.Typography.secondary)
        }
        .foregroundStyle(active ? AnyShapeStyle(GohTheme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: General

    private var generalCard: some View {
        GohModuleCard(padding: 0) {
            VStack(spacing: 0) {
                settingRow {
                    toggleRow(
                        "Launch at login",
                        subtitle: loginItemStatus == .unsupported ? "Not available in this build" : nil,
                        isOn: $launchAtLoginEnabled,
                        disabled: loginItemStatus == .unsupported,
                        accessibility: "Launch at login")
                        .onChange(of: launchAtLoginEnabled) { _, newValue in applyLoginItemToggle(newValue) }
                    if loginItemStatus == .requiresApproval {
                        captionLine("Enabled — approve in System Settings → General → Login Items.", color: .secondary)
                    }
                    if let loginItemError {
                        captionLine(loginItemError, color: GohTheme.error)
                    }
                }

                hairline

                settingRow {
                    toggleRow(
                        "Show progress on the icon",
                        subtitle: "Brighten the arrow as a download completes",
                        isOn: $showProgressOnIcon,
                        accessibility: "Show download progress on the menu-bar icon")
                        .onChange(of: showProgressOnIcon) { _, newValue in preferences.showProgressOnIcon = newValue }
                }

                hairline

                settingRow {
                    toggleRow(
                        "Notify when downloads finish",
                        subtitle: nil,
                        isOn: $notificationsEnabled,
                        accessibility: "Enable completion notifications")
                        .onChange(of: notificationsEnabled) { _, newValue in preferences.notificationsEnabled = newValue }
                }
            }
        }
    }

    // MARK: Building blocks

    private func settingRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func toggleRow(
        _ title: String,
        subtitle: String?,
        isOn: Binding<Bool>,
        disabled: Bool = false,
        accessibility: String
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GohTheme.Typography.rowTitle).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(GohTheme.accent)
                .disabled(disabled)
                .accessibilityLabel(accessibility)
        }
    }

    private func captionLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GohTheme.Typography.secondary)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hairline: some View {
        Rectangle().fill(GohTheme.separator).frame(height: GohTheme.Metrics.hairline)
    }

    private var footer: some View {
        Text(buildLine)
            .font(GohTheme.Typography.secondary)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
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
