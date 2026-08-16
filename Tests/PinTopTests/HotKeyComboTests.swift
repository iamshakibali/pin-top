import XCTest
import Carbon
@testable import PinTop

final class HotKeyComboTests: XCTestCase {
    func testDefaultComboIsOptionCommandP() {
        XCTAssertEqual(HotKeyCombo.default.keyCode, 35)
        XCTAssertEqual(HotKeyCombo.default.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotKeyCombo.default.displayText, "⌥⌘P")
    }

    func testStorageStringRoundTrip() {
        let combo = HotKeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey)) // ⌘X
        let restored = HotKeyCombo(storageString: combo.storageString)
        XCTAssertEqual(restored, combo)
    }

    func testInvalidStorageStringReturnsNil() {
        XCTAssertNil(HotKeyCombo(storageString: "not-a-combo"))
        XCTAssertNil(HotKeyCombo(storageString: "35"))
        XCTAssertNil(HotKeyCombo(storageString: "-1:2304"))
    }

    func testDisplayTextOrdersModifiersControlOptionShiftCommand() {
        let combo = HotKeyCombo(
            keyCode: 35,
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(combo.displayText, "⌃⌥⇧⌘P")
    }

    func testUnknownKeyCodeFallsBack() {
        let combo = HotKeyCombo(keyCode: 999, carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(combo.displayText, "⌘Key 999")
    }

    func testValidation() {
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(cmdKey | optionKey))) // ⌥⌘P
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(controlKey)))         // ⌃P
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 122, carbonModifiers: 0))                        // bare F1
        XCTAssertFalse(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: 0))                        // bare P
        XCTAssertFalse(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(shiftKey)))         // ⇧P only
    }

    func testFunctionKeyNames() {
        XCTAssertEqual(HotKeyCombo.keyName(for: 122), "F1")
        XCTAssertEqual(HotKeyCombo.keyName(for: 111), "F12")
        XCTAssertEqual(HotKeyCombo.keyName(for: 35), "P")
    }
}
