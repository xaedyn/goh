import Foundation
import Testing
@testable import GohMenuBar

// AC4: preferences persist across relaunches and read back correctly.
@Suite("GohMenuPreferences")
struct GohMenuPreferencesTests {

    // AC4: absent key reads as false (default OFF for both toggles)
    @Test func defaultsFalseWhenAbsent() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(store.notificationsEnabled == false)
        #expect(store.launchAtLoginEnabled == false)
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
