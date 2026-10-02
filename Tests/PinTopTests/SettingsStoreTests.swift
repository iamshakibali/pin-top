import XCTest
import Carbon
@testable import PinTop

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "PinTopTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
    }

    func testDefaultsOnFreshInstall() {
        let store = SettingsStore(defaults: suite)
        XCTAssertTrue(store.autoCheckUpdates)
        XCTAssertEqual(store.hotkey, .default)
        XCTAssertEqual(store.lastAutoUpdateCheck, .distantPast)
    }

    func testAutoCheckUpdatesPersists() {
        let store = SettingsStore(defaults: suite)
        store.autoCheckUpdates = false
        XCTAssertFalse(SettingsStore(defaults: suite).autoCheckUpdates)
    }

    func testHotkeyPersistsRoundTrip() {
        let store = SettingsStore(defaults: suite)
        let combo = HotKeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey)) // ⌘X
        store.hotkey = combo
        XCTAssertEqual(SettingsStore(defaults: suite).hotkey, combo)
    }

    func testUnpinHotkeyDefaultsToOptionCommandU() {
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.unpinHotkey, .defaultUnpin)
    }

    func testUnpinHotkeyPersistsRoundTrip() {
        let store = SettingsStore(defaults: suite)
        let combo = HotKeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey)) // ⌘X
        store.unpinHotkey = combo
        XCTAssertEqual(SettingsStore(defaults: suite).unpinHotkey, combo)
    }

    func testCorruptUnpinHotkeyStringFallsBackToDefault() {
        suite.set("garbage", forKey: "unpinHotkey")
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.unpinHotkey, .defaultUnpin)
    }

    func testCorruptHotkeyStringFallsBackToDefault() {
        suite.set("garbage", forKey: "pinHotkey")
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.hotkey, .default)
    }

    func testLastAutoUpdateCheckPersists() {
        let store = SettingsStore(defaults: suite)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.lastAutoUpdateCheck = stamp
        XCTAssertEqual(SettingsStore(defaults: suite).lastAutoUpdateCheck, stamp)
    }
}
