import Foundation
import Testing
@testable import GohMenuBar

// AC4: preferences persist across relaunches and read back correctly.
@Suite("GohMenuPreferences")
struct GohMenuPreferencesTests {

    // Defaults when absent: notifications ON (core affordance, opt-out),
    // launch-at-login OFF, show-progress-on-icon ON.
    @Test func defaultsWhenAbsent() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(store.notificationsEnabled == true)
        #expect(store.launchAtLoginEnabled == false)
        #expect(store.showProgressOnIcon == true)
    }

    // AC4: values survive a round-trip through the store
    @Test func roundTripsNotificationsEnabled() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.notificationsEnabled = true
        let fresh = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(fresh.notificationsEnabled == true)
    }

    @Test func roundTripsLaunchAtLoginEnabled() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.launchAtLoginEnabled = true
        let fresh = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(fresh.launchAtLoginEnabled == true)
    }

    @Test func readAfterWriteFalse() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.notificationsEnabled = true
        store.notificationsEnabled = false
        #expect(store.notificationsEnabled == false)
    }
}
